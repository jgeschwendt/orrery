defmodule Orrery.Memory.LocksTest do
  use ExUnit.Case, async: false

  alias Orrery.Memory.Locks

  setup do
    base = Path.join(System.tmp_dir!(), "locks_test_#{System.unique_integer([:positive])}")
    memory = Path.join(base, "memory")
    File.mkdir_p!(memory)
    Application.put_env(:orrery, :memory_root, memory)

    on_exit(fn ->
      Application.delete_env(:orrery, :memory_root)
      Application.delete_env(:orrery, :lock_commit_budget_ms)
      Application.delete_env(:orrery, :lock_heartbeat_ms)
      File.rm_rf!(base)
    end)

    %{
      commit_lock: Path.join(memory, ".commit.lock"),
      memory: memory,
      pipeline_lock: Path.join(memory, ".sweep.lock")
    }
  end

  # Holds `kind` in a separate monitored process until sent `:release`; sends the
  # parent `:holding` once the lock is in hand. Returns `{pid, ref}`.
  defp hold(kind) do
    parent = self()

    spawn_monitor(fn ->
      Locks.with_lock(kind, fn ->
        send(parent, :holding)

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  # Busy-polls `fun` until it returns true or a 2s deadline elapses. Used only to
  # observe wall-clock effects (an advancing mtime) that no message can signal.
  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
      true -> eventually(fun, deadline)
    end
  end

  test "the pipeline lock is mutually exclusive" do
    {holder, ref} = hold(:pipeline)
    assert_receive :holding

    assert Locks.try_pipeline_lock() == :locked

    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, ^holder, :normal}

    assert Locks.try_pipeline_lock() == :ok
    assert Locks.release_pipeline_lock() == :ok
  end

  test "with_lock/2 releases the pipeline lock even when fun raises" do
    catch_error(Locks.with_lock(:pipeline, fn -> raise "boom" end))
    assert Locks.try_pipeline_lock() == :ok
    Locks.release_pipeline_lock()
  end

  test "a commit acquire gives up with {:error, :locked} once the budget is spent" do
    Application.put_env(:orrery, :lock_commit_budget_ms, 50)
    {holder, ref} = hold(:commit)
    assert_receive :holding

    assert Locks.with_lock(:commit, fn -> :ran end) == {:error, :locked}

    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, ^holder, :normal}

    assert Locks.with_lock(:commit, fn -> :ran end) == {:ok, :ran}
  end

  test "a stale pipeline lock is stolen", %{pipeline_lock: path} do
    File.mkdir!(path)
    File.touch!(path, System.os_time(:second) - (15 * 60 + 30))

    assert Locks.try_pipeline_lock() == :ok
    Locks.release_pipeline_lock()
  end

  test "a stale commit lock is stolen", %{commit_lock: path} do
    File.mkdir!(path)
    File.touch!(path, System.os_time(:second) - (60 + 30))

    assert Locks.with_lock(:commit, fn -> :ran end) == {:ok, :ran}
  end

  test "a fresh commit lock is not stolen", %{commit_lock: path} do
    Application.put_env(:orrery, :lock_commit_budget_ms, 50)
    File.mkdir!(path)
    File.touch!(path, System.os_time(:second))

    assert Locks.with_lock(:commit, fn -> :ran end) == {:error, :locked}
  end

  test "the pipeline holder heartbeats the lock mtime forward", %{pipeline_lock: path} do
    Application.put_env(:orrery, :lock_heartbeat_ms, 20)
    {holder, ref} = hold(:pipeline)
    assert_receive :holding

    # Drag the mtime deep into the past; a live heartbeat must pull it back to now.
    backdated = System.os_time(:second) - 300
    File.touch!(path, backdated)

    eventually(fn ->
      {:ok, %{mtime: mtime}} = File.stat(path, time: :posix)
      mtime > backdated
    end)

    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, ^holder, :normal}
  end
end
