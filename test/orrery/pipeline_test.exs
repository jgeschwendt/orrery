defmodule Orrery.Memory.PipelineTest do
  use ExUnit.Case, async: false

  alias Orrery.Memory.Locks
  alias Orrery.Memory.Pipeline
  alias Orrery.Memory.Pipeline.Runner

  @project "-tmp-proj"

  setup do
    base = Path.join(System.tmp_dir!(), "pipeline_test_#{System.unique_integer([:positive])}")
    memory = Path.join(base, "memory")
    projects = Path.join(base, "projects")
    log = Path.join(base, "log")
    File.mkdir_p!(memory)
    File.mkdir_p!(projects)
    File.mkdir_p!(Path.join(log, "archive"))
    Application.put_env(:orrery, :memory_root, memory)
    Application.put_env(:orrery, :projects_dir, projects)
    Application.put_env(:orrery, :log_root, log)
    Application.put_env(:orrery, :archive_root, Path.join(log, "archive"))

    on_exit(fn ->
      Application.delete_env(:orrery, :memory_root)
      Application.delete_env(:orrery, :projects_dir)
      Application.delete_env(:orrery, :log_root)
      Application.delete_env(:orrery, :archive_root)
      Application.delete_env(:orrery, :claude_runner)
      File.rm_rf!(base)
    end)

    # A fresh, isolated Task.Supervisor + worker per test (the app starts neither in :test).
    # The worker runs its entry tasks under the globally-named TaskSup, so it must exist.
    start_supervised!({Task.Supervisor, name: Orrery.Memory.Pipeline.TaskSup})
    pid = start_supervised!({Pipeline, name: :test_pipeline})
    %{log: log, pid: pid}
  end

  # ── helpers ───────────────────────────────────────────────
  # An archived (gzip) transcript under the @log archive — enqueue accepts a session
  # that is already archived, and the worker reads it via `Transcripts.parse_archived/1`.
  defp write_archive(log, id, texts) do
    dir = Path.join([log, "archive", "2026-07-13"])
    File.mkdir_p!(dir)

    lines =
      Enum.map(texts, fn t ->
        Jason.encode!(%{
          "type" => "user",
          "cwd" => "/tmp/proj",
          "timestamp" => "2026-07-13T00:00:00Z",
          "message" => %{"content" => t}
        })
      end)

    data = :zlib.gzip(Enum.join(lines, "\n") <> "\n")
    File.write!(Path.join(dir, id <> ".jsonl.gz"), data)
  end

  # Extraction yields one candidate the judge then drops → outcome "dissolved". The
  # counter agent lets a test assert exactly how many extract calls the CLI seam saw.
  defp stub_claude(agent) do
    Application.put_env(:orrery, :claude_runner, fn prompt, _opts ->
      cond do
        String.contains?(prompt, "memory-quality judge") ->
          {:ok, %{output: %{"verdicts" => [%{"name" => "Fact", "verdict" => "drop"}]}, cost: 0.0}}

        String.contains?(prompt, "distill an ENTIRE") ->
          Agent.update(agent, &(&1 + 1))

          {:ok,
           %{
             output: %{
               "memories" => [
                 %{"name" => "Fact", "description" => "d", "type" => "reference", "body" => "b"}
               ]
             },
             cost: 0.0
           }}

        true ->
          {:ok, %{output: %{"memories" => []}, cost: 0.0}}
      end
    end)
  end

  # A raw queue append, as the shell `/dissolve` does — no enqueue call, so nothing is
  # kicked until the Watcher event arrives.
  defp append_queue_line(id, title) do
    File.mkdir_p!(Orrery.Memory.memory_root())

    line =
      Jason.encode!(%{
        "id" => id,
        "cwd" => "/tmp/proj",
        "title" => title,
        "queued_at" => "2026-07-13T00:00:00Z",
        "source" => "dissolve"
      })

    File.write!(Runner.queue_path(), line <> "\n", [:append])
  end

  defp queue_line_count do
    case File.read(Runner.queue_path()) do
      {:ok, txt} -> txt |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  # ── tests ─────────────────────────────────────────────────
  test "a duplicate enqueue is a no-op: one queue line, one extract call", %{log: log} do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    stub_claude(agent)
    Pipeline.subscribe()
    write_archive(log, "dup", ["a", "b", "c", "d", "e"])

    assert Pipeline.enqueue_session(@project, "dup", "t", :test_pipeline) == {:ok, :queued}
    assert Pipeline.enqueue_session(@project, "dup", "t", :test_pipeline) == {:ok, :noop}

    assert_receive {:pipeline, "dup", {:done, _}}, 2000
    assert queue_line_count() == 1
    assert Agent.get(agent, & &1) == 1
  end

  test "event sequence: queued → extracting → judging → done", %{log: log} do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    stub_claude(agent)
    Pipeline.subscribe()
    write_archive(log, "seq", ["a", "b", "c", "d", "e"])

    assert Pipeline.enqueue_session(@project, "seq", "t", :test_pipeline) == {:ok, :queued}

    assert_receive {:pipeline, "seq", :queued}, 2000
    assert_receive {:pipeline, "seq", :extracting}, 2000
    assert_receive {:pipeline, "seq", :judging}, 2000
    assert_receive {:pipeline, "seq", {:done, %{outcome: "dissolved"}}}, 2000
  end

  test "enqueue of an unknown session is not_found" do
    assert Pipeline.enqueue_session(@project, "ghost", "t", :test_pipeline) ==
             {:error, :not_found}
  end

  test "worker defers while an external process holds the pipeline lock", %{log: log} do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    stub_claude(agent)
    Pipeline.subscribe()
    write_archive(log, "held", ["a", "b", "c", "d", "e"])

    # An external holder (a running sweep) owns the lock: the worker must not process.
    lock = Path.join(Orrery.Memory.memory_root(), ".sweep.lock")
    File.mkdir_p!(lock)

    assert Pipeline.enqueue_session(@project, "held", "t", :test_pipeline) == {:ok, :queued}
    assert_receive {:pipeline, "held", :queued}, 2000
    refute_receive {:pipeline, "held", :extracting}, 300

    # Release the external lock and re-kick — the worker now proceeds.
    File.rmdir(lock)
    Pipeline.kick(:test_pipeline)
    assert_receive {:pipeline, "held", :extracting}, 2000
    assert_receive {:pipeline, "held", {:done, _}}, 2000
  end

  test "a Watcher files_changed event kicks a shell-appended queue line", %{log: log, pid: pid} do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    stub_claude(agent)
    Pipeline.subscribe()
    write_archive(log, "shell", ["a", "b", "c", "d", "e"])

    # The shell appended a queue line; no enqueue call fired, so nothing is in flight yet.
    append_queue_line("shell", "t")
    refute_receive {:pipeline, "shell", :extracting}, 300

    # The Watcher's clause delivers this tuple; the idle worker picks the line up.
    send(pid, {:pipeline, :files_changed})
    assert_receive {:pipeline, "shell", :extracting}, 2000
    assert_receive {:pipeline, "shell", {:done, _}}, 2000
  end

  @tag capture_log: true
  test "a Task crash mid-extract errors the entry, which stays pending", %{log: log} do
    Application.put_env(:orrery, :claude_runner, fn prompt, _opts ->
      if String.contains?(prompt, "distill an ENTIRE"), do: raise("boom")
      {:ok, %{output: %{"memories" => []}, cost: 0.0}}
    end)

    Pipeline.subscribe()
    write_archive(log, "boom", ["a", "b", "c", "d", "e"])

    assert Pipeline.enqueue_session(@project, "boom", "t", :test_pipeline) == {:ok, :queued}
    assert_receive {:pipeline, "boom", {:error, _}}, 2000

    # No ledger line was written, so the entry is still pending for the next kick.
    assert Enum.any?(Runner.pending(), &(&1["id"] == "boom"))
    # The worker released the lock and returned to idle after the crash.
    assert Locks.try_pipeline_lock() == :ok
    Locks.release_pipeline_lock()
  end
end
