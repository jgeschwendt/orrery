defmodule Orrery.Memory.Pipeline do
  @moduledoc """
  The in-app worker that drives the dissolve-queue promptly and broadcasts stage-by-
  stage progress — the sole in-app writer of the pipeline flow. LiveViews call only
  this module; the launchd `mix memory.sweep` stays the app-down backstop.

  ## Serial worker, held across a batch

  On a kick (an `enqueue_session/3` call, the 5-minute tick, or a resumed job) the
  worker takes the **pipeline lock** non-blockingly via `Locks.try_pipeline_lock/0`.
  A held lock — the hourly sweep is running — simply defers; the next kick retries.
  After acquiring, it **re-derives** `Runner.pending/1` (killing the worker↔sweep
  double-process window), then processes that snapshot one entry at a time in a
  monitored `Task` so `status/0`/enqueues stay responsive. The lock is held across the
  whole batch and heartbeated on a timer; it releases when the batch drains.

  Crash safety needs no durable in-progress marker: `Runner.process_entry/3` ledgers
  each outcome itself, so a `Task` crash leaves no ledger line ⇒ the entry stays
  pending ⇒ it is reprocessed on the next kick.

  ## Jobs

  `request_sweep/0` / `request_dream/1` / `request_merge/2` run the long claude passes
  off the caller so browser disconnects don't abort them. They are refused with
  `{:error, :busy}` unless the worker is idle. `request_sweep/0` runs `Sweep.run/0`,
  which takes the pipeline lock itself — so it is NOT pre-acquired here; dream/merge
  wrap their work in `Locks.with_lock(:pipeline, …)`.

  ## Events (`Phoenix.PubSub`, topic `"pipeline"`)

    * `{:pipeline, id, :queued | :extracting | :judging | :waiting}`
    * `{:pipeline, id, {:done, %{outcome, bank, committed, staged, dropped}}}` — only
      after the ledger line has landed
    * `{:pipeline, id, {:error, reason}}`
    * `{:pipeline, :job, {:started | :finished, kind, info}}`
  """
  use GenServer

  alias Orrery.{Memory, Store, Transcripts}
  alias Orrery.Memory.{Locks, Pipeline.Runner, Sweep}

  @heartbeat_ms 60_000
  @task_sup Orrery.Memory.Pipeline.TaskSup
  @tick_ms 5 * 60 * 1000
  @topic "pipeline"

  # ── API ───────────────────────────────────────────────────
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Enqueue a session for dissolution. Guards the request, archives the live transcript
  (same semantics as `/dissolve` + `/delete`), appends ONE append-only queue line, and
  kicks the worker. `{:ok, :noop}` when the id is already pending, in-flight, or
  permanently ledgered (a duplicate dissolve is a silent no-op).
  """
  def enqueue_session(project, id, title, server \\ __MODULE__) do
    GenServer.call(server, {:enqueue, project, id, title})
  end

  @doc "A snapshot of the queue, the in-flight entry, and the current job — built from `Runner.pending/1` plus in-memory worker state."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Subscribe the caller to pipeline events on the `\"pipeline\"` topic."
  def subscribe, do: Phoenix.PubSub.subscribe(Orrery.PubSub, @topic)

  @doc "Nudge the worker to try the queue now (a no-op while it is busy)."
  def kick(server \\ __MODULE__), do: GenServer.cast(server, :kick)

  @doc "Run a full sweep off the caller. `{:error, :busy}` unless the worker is idle."
  def request_sweep(server \\ __MODULE__), do: GenServer.call(server, :request_sweep)

  @doc "Run the dream over `bank` off the caller. `{:error, :busy}` unless idle."
  def request_dream(bank, server \\ __MODULE__),
    do: GenServer.call(server, {:request_dream, bank})

  @doc "Merge `files` in `bank` off the caller. `{:error, :busy}` unless idle."
  def request_merge(bank, files, server \\ __MODULE__),
    do: GenServer.call(server, {:request_merge, bank, files})

  # ── init ──────────────────────────────────────────────────
  @impl true
  def init(_opts) do
    subscribe()
    schedule_tick()
    {:ok, %{job: :idle, in_flight: nil, task_ref: nil, queue_batch: [], heartbeat_timer: nil}}
  end

  # ── enqueue ───────────────────────────────────────────────
  @impl true
  def handle_call({:enqueue, project, id, title}, _from, state) do
    case classify_enqueue(project, id, state) do
      :ok ->
        append_queue(%{
          "id" => id,
          "cwd" => enqueue_cwd(project),
          "title" => title,
          "queued_at" => now_iso(),
          "source" => "dashboard"
        })

        broadcast({:pipeline, id, :queued})
        {:reply, {:ok, :queued}, maybe_start(state)}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call(:status, _from, state) do
    inflight_id = state.in_flight && state.in_flight.id

    queue =
      Runner.pending()
      |> Enum.reject(&(&1["id"] == inflight_id))
      |> Enum.with_index()
      |> Enum.map(fn {e, i} ->
        %{
          id: e["id"],
          cwd: e["cwd"],
          title: e["title"],
          queued_at: e["queued_at"],
          attempts: e["attempts"],
          last_error: e["last_error"],
          position: i
        }
      end)

    {:reply, %{queue: queue, in_flight: state.in_flight, job: state.job}, state}
  end

  def handle_call(:request_sweep, _from, %{job: :idle} = state) do
    broadcast({:pipeline, :job, {:started, :sweep, nil}})
    task = run_task(fn -> Sweep.run() end)
    {:reply, :ok, %{state | job: :sweep, task_ref: task.ref}}
  end

  def handle_call({:request_dream, bank}, _from, %{job: :idle} = state) do
    broadcast({:pipeline, :job, {:started, :dream, bank}})
    task = run_task(fn -> Locks.with_lock(:pipeline, fn -> Memory.Dream.run(bank) end) end)
    {:reply, :ok, %{state | job: :dream, task_ref: task.ref}}
  end

  def handle_call({:request_merge, bank, files}, _from, %{job: :idle} = state) do
    broadcast({:pipeline, :job, {:started, :merge, bank}})

    task =
      run_task(fn -> Locks.with_lock(:pipeline, fn -> Memory.merge_memories(bank, files) end) end)

    {:reply, :ok, %{state | job: :merge, task_ref: task.ref}}
  end

  # A job request while non-idle is refused — the worker holds the pipeline lock or a
  # job task is already running. These fall through from the `%{job: :idle}` heads above.
  def handle_call(:request_sweep, _from, state), do: {:reply, {:error, :busy}, state}
  def handle_call({:request_dream, _bank}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:request_merge, _bank, _files}, _from, state),
    do: {:reply, {:error, :busy}, state}

  # Client-supplied strings must be safe path components; a live transcript is archived
  # at enqueue time; an archive-on-exit mark belongs to the session-end machinery.
  defp classify_enqueue(project, id, state) do
    cond do
      not (Store.component?(project) and Store.component?(id)) -> {:error, :invalid}
      Sweep.marked_archive_on_exit?(id) -> {:error, :archive_on_exit}
      noop?(id, state) -> {:ok, :noop}
      true -> ensure_archived(project, id)
    end
  end

  # A live transcript is archived (then removed) now — identical to `/dissolve`+`/delete`.
  # With no live transcript, an existing @log archive is enough; neither → not found.
  defp ensure_archived(project, id) do
    cond do
      Transcripts.get_session(project, id) != nil ->
        Transcripts.delete_session(project, id)
        :ok

      Transcripts.parse_archived(id) != nil ->
        :ok

      true ->
        {:error, :not_found}
    end
  end

  # in-flight (this hold's head), queued for this hold (queue_batch), currently pending,
  # or permanently ledgered — any of these makes a re-enqueue a silent no-op.
  defp noop?(id, state) do
    (state.in_flight && state.in_flight.id == id) ||
      Enum.any?(state.queue_batch, &(&1["id"] == id)) ||
      Enum.any?(Runner.pending(), &(&1["id"] == id)) || permanent?(id)
  end

  # A ledgered outcome is permanent unless it is `error` (which retries) — inbox audit
  # lines carry no id, so `Runner.ledger/0` never surfaces one here.
  defp permanent?(id) do
    case Runner.ledger()[id] do
      nil -> false
      %{"outcome" => "error"} -> false
      _ -> true
    end
  end

  # cwd is display/status metadata (the worker re-derives the real cwd from the archived
  # transcript); decode it from the project dir name, falling back to the raw project.
  defp enqueue_cwd(project) do
    case Transcripts.decode_project(project) do
      cwd when is_binary(cwd) and cwd != "" -> cwd
      _ -> project
    end
  end

  # ── worker kick ───────────────────────────────────────────
  @impl true
  def handle_cast(:kick, state), do: {:noreply, maybe_start(state)}

  def handle_cast({:progress, id, stage}, state) do
    broadcast({:pipeline, id, stage})
    in_flight = state.in_flight && %{state.in_flight | stage: stage}
    {:noreply, %{state | in_flight: in_flight}}
  end

  defp maybe_start(%{job: :idle} = state), do: start_queue(state)
  defp maybe_start(state), do: state

  # Acquire the pipeline lock non-blockingly; a held lock defers (stays idle). After
  # acquiring, re-derive pending and process the snapshot head, holding the lock (and
  # heartbeating it) across the whole batch.
  defp start_queue(state) do
    case Locks.try_pipeline_lock() do
      :locked ->
        state

      :ok ->
        case Runner.pending() do
          [] ->
            Locks.release_pipeline_lock()
            state

          [head | rest] ->
            start_entry(
              %{state | job: :queue, queue_batch: rest, heartbeat_timer: schedule_heartbeat()},
              head
            )
        end
    end
  end

  defp start_entry(state, entry) do
    id = entry["id"]
    worker = self()
    progress = fn stage -> GenServer.cast(worker, {:progress, id, stage}) end
    task = run_task(fn -> Runner.process_entry(entry, DateTime.utc_now(), progress) end)

    %{
      state
      | task_ref: task.ref,
        in_flight: %{id: id, stage: :extracting, title: entry["title"], started_at: now_iso()}
    }
  end

  # ── task completion ───────────────────────────────────────
  @impl true
  def handle_info({ref, result}, %{task_ref: ref, job: :queue} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_entry(result, state)}
  end

  def handle_info({ref, result}, %{task_ref: ref, job: job} = state)
      when job in [:sweep, :dream, :merge] do
    Process.demonitor(ref, [:flush])
    broadcast({:pipeline, :job, {:finished, job, result}})
    {:noreply, resume(%{state | job: :idle, task_ref: nil})}
  end

  # A Task crash: no ledger line landed, so the entry stays pending and is reprocessed
  # on the next kick. Move on to the next entry in the current batch.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref, job: :queue} = state) do
    if state.in_flight, do: broadcast({:pipeline, state.in_flight.id, {:error, reason}})
    {:noreply, continue(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref, job: job} = state)
      when job in [:sweep, :dream, :merge] do
    broadcast({:pipeline, :job, {:finished, job, {:error, reason}}})
    {:noreply, resume(%{state | job: :idle, task_ref: nil})}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, maybe_start(state)}
  end

  # A Watcher `.jsonl`-under-memory-root write (a shell `/dissolve` append). Kick only
  # while idle — `start_queue` re-derives pending, so an idle+empty kick is a cheap
  # no-op. While a batch or job runs we ignore it: the worker's own ledger writes echo
  # back through the Watcher, and re-kicking mid-batch would loop hot.
  def handle_info({:pipeline, :files_changed}, %{job: :idle} = state),
    do: {:noreply, maybe_start(state)}

  def handle_info({:pipeline, :files_changed}, state), do: {:noreply, state}

  def handle_info(:heartbeat, %{job: :queue} = state) do
    Locks.heartbeat_pipeline()
    {:noreply, %{state | heartbeat_timer: schedule_heartbeat()}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish_entry(result, state) do
    id = result.id

    case result.outcome do
      "waiting" -> broadcast({:pipeline, id, :waiting})
      "error" -> broadcast({:pipeline, id, {:error, ledger_error(id)}})
      _ -> broadcast({:pipeline, id, {:done, done_payload(id)}})
    end

    continue(state)
  end

  defp continue(state) do
    state = %{state | task_ref: nil, in_flight: nil}

    case state.queue_batch do
      [next | rest] -> start_entry(%{state | queue_batch: rest}, next)
      [] -> release_and_idle(state)
    end
  end

  defp release_and_idle(state) do
    cancel_heartbeat(state.heartbeat_timer)
    Locks.release_pipeline_lock()
    %{state | job: :idle, queue_batch: [], heartbeat_timer: nil}
  end

  # The {:done} payload is read back from the ledger the worker just wrote — so it is
  # broadcast only after the ledger line has landed (a `committed` count from the
  # recorded memory names, plus the bank and drop/stage tallies).
  defp done_payload(id) do
    e = Runner.ledger()[id] || %{}

    %{
      outcome: e["outcome"],
      bank: e["bank"],
      committed: length(e["memories"] || []),
      dropped: e["dropped"],
      staged: e["staged"]
    }
  end

  defp ledger_error(id), do: (Runner.ledger()[id] || %{})["error"]

  # After a job finishes, resume the queue — any lines that arrived while it ran drain now.
  defp resume(state) do
    kick(self())
    state
  end

  # ── plumbing ──────────────────────────────────────────────
  defp run_task(fun), do: Task.Supervisor.async_nolink(@task_sup, fun)

  defp append_queue(map) do
    File.mkdir_p!(Memory.memory_root())
    File.write!(Runner.queue_path(), Jason.encode!(map) <> "\n", [:append])
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Orrery.PubSub, @topic, msg)

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat_ms)
  defp cancel_heartbeat(nil), do: :ok
  defp cancel_heartbeat(ref), do: Process.cancel_timer(ref)

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
