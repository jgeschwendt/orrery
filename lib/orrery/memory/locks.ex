defmodule Orrery.Memory.Locks do
  @commit_backoff_ms 10
  @commit_budget_ms 5_000
  @commit_lock ".commit.lock"
  @commit_stale_s 60
  @heartbeat_ms 60_000
  @pipeline_lock ".sweep.lock"
  @pipeline_stale_s 15 * 60

  @moduledoc """
  Two named `mkdir(2)` locks that serialize memory-pipeline work across OS
  processes — the running app and the launchd `mix memory.sweep` both contend for
  the same directories under `Orrery.Memory.memory_root/0`.

  `mkdir` is atomic on every POSIX filesystem: exactly one caller creates the
  directory, everyone else gets `:eexist`. Liveness comes from the lock's
  directory mtime — a crashed holder leaves its lock behind, so each lock defines
  a staleness window after which a fresh caller steals it.

  ## The two locks

    * `:pipeline` (`#{@pipeline_lock}` — name kept deliberately, so that an old
      process and a new one can never hold *different* locks) guards the
      long-held extraction / sweep / dream work. The holder heartbeats the lock's
      mtime every #{div(@heartbeat_ms, 1000)}s; a lock left un-touched for
      #{div(@pipeline_stale_s, 60)} min is presumed dead and stolen.

    * `:commit` (`#{@commit_lock}`) guards the short read-modify-write mutations
      of the staging/ledger files. Held for milliseconds, never across a claude
      call. Acquisition spins with #{@commit_backoff_ms}ms backoff up to a
      ~#{@commit_budget_ms}ms budget, then gives up with `{:error, :locked}`; a
      lock older than #{@commit_stale_s}s is stolen.

  ## Ordering

  A caller that needs both locks MUST take `:pipeline` first, then `:commit`, and
  release in reverse. Never acquire `:pipeline` while holding `:commit` — that is
  the one ordering that can deadlock the app against the launchd sweep.
  """

  @doc """
  Runs `fun` while holding `kind`, releasing in an `after` no matter how `fun`
  returns.

    * `:pipeline` acquires without blocking; a held lock yields `{:error,
      :locked}` immediately. While held, a linked heartbeat drags the lock's mtime
      forward so a slow-but-alive holder is never mistaken for a dead one.
    * `:commit` spins with bounded backoff up to its budget, then `{:error,
      :locked}`.

  Returns `{:ok, fun_result}` on success.
  """
  def with_lock(:pipeline, fun) when is_function(fun, 0) do
    case try_pipeline_lock() do
      :ok ->
        heartbeat = start_heartbeat(path(:pipeline))

        try do
          {:ok, fun.()}
        after
          stop_heartbeat(heartbeat)
          release_pipeline_lock()
        end

      :locked ->
        {:error, :locked}
    end
  end

  def with_lock(:commit, fun) when is_function(fun, 0) do
    case acquire_commit(System.monotonic_time(:millisecond) + commit_budget_ms()) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          release(:commit)
        end

      :locked ->
        {:error, :locked}
    end
  end

  @doc """
  Non-blocking pipeline acquire for a holder that spans messages (the worker):
  `:ok` on success, `:locked` if another holder has it. The caller owns release
  via `release_pipeline_lock/0` and gets no heartbeat — use `with_lock/2` for that.
  """
  def try_pipeline_lock, do: acquire(:pipeline)

  @doc "Releases a pipeline lock taken with `try_pipeline_lock/0`."
  def release_pipeline_lock, do: release(:pipeline)

  @doc """
  Drags the pipeline lock's mtime forward — a manual heartbeat for a holder that took
  the lock via `try_pipeline_lock/0` (which, unlike `with_lock/2`, spawns no automatic
  heartbeat). The `Pipeline` worker calls this on its own timer while holding the lock
  across a queue batch, so a slow-but-alive batch is never mistaken for a dead holder.
  """
  def heartbeat_pipeline, do: File.touch(path(:pipeline))

  # ── acquire / steal ───────────────────────────────────────
  defp acquire(kind) do
    File.mkdir_p!(Orrery.Memory.memory_root())

    case File.mkdir(path(kind)) do
      :ok -> :ok
      {:error, :eexist} -> steal_if_stale(kind)
      _ -> :locked
    end
  end

  # A held lock whose mtime is older than its window belongs to a crashed holder;
  # drop and re-create it. The rmdir→mkdir pair is not itself atomic, but a losing
  # racer just sees :eexist again and re-checks — no lock is ever double-held.
  defp steal_if_stale(kind) do
    with {:ok, %{mtime: mtime}} <- File.stat(path(kind), time: :posix),
         true <- System.os_time(:second) - mtime > stale_s(kind),
         _ <- File.rmdir(path(kind)),
         :ok <- File.mkdir(path(kind)) do
      :ok
    else
      _ -> :locked
    end
  end

  defp acquire_commit(deadline) do
    case acquire(:commit) do
      :ok ->
        :ok

      :locked ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@commit_backoff_ms)
          acquire_commit(deadline)
        else
          :locked
        end
    end
  end

  defp release(kind), do: File.rmdir(path(kind))

  # ── heartbeat ─────────────────────────────────────────────
  defp start_heartbeat(path) do
    interval = heartbeat_ms()
    spawn_link(fn -> heartbeat_loop(path, interval) end)
  end

  defp heartbeat_loop(path, interval) do
    receive do
      :stop -> :ok
    after
      interval ->
        File.touch(path)
        heartbeat_loop(path, interval)
    end
  end

  defp stop_heartbeat(heartbeat), do: send(heartbeat, :stop)

  # ── config ────────────────────────────────────────────────
  # Overridable so tests can shrink the windows they would otherwise wait out.
  defp commit_budget_ms,
    do: Application.get_env(:orrery, :lock_commit_budget_ms, @commit_budget_ms)

  defp heartbeat_ms, do: Application.get_env(:orrery, :lock_heartbeat_ms, @heartbeat_ms)

  defp path(:commit), do: Path.join(Orrery.Memory.memory_root(), @commit_lock)
  defp path(:pipeline), do: Path.join(Orrery.Memory.memory_root(), @pipeline_lock)

  defp stale_s(:commit), do: @commit_stale_s
  defp stale_s(:pipeline), do: @pipeline_stale_s
end
