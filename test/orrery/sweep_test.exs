defmodule Orrery.Memory.SweepTest do
  use ExUnit.Case, async: false

  alias Orrery.Memory.Sweep

  # No fixture in this file may be BOTH quiescent and non-trivial — that combination
  # is the one that spends a real `claude` call.

  setup do
    base = Path.join(System.tmp_dir!(), "sweep_test_#{System.unique_integer([:positive])}")
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
      File.rm_rf!(base)
    end)

    %{projects: projects, log: log, memory: memory}
  end

  defp write_session(projects, id, messages, at) do
    dir = Path.join(projects, "-tmp-proj")
    File.mkdir_p!(dir)

    lines =
      Enum.map(messages, fn text ->
        Jason.encode!(%{
          "type" => "user",
          "cwd" => "/tmp/proj",
          "timestamp" => at,
          "message" => %{"content" => text}
        })
      end)

    File.write!(Path.join(dir, id <> ".jsonl"), Enum.join(lines, "\n") <> "\n")
  end

  defp iso_hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h * 3600) |> DateTime.to_iso8601()

  test "fresh sessions are left alone", %{projects: projects} do
    write_session(
      projects,
      "fresh",
      ["did a thing", "and another", "and more", "and more"],
      iso_hours_ago(1)
    )

    report = Sweep.run()

    assert report.considered == 0
    assert report.results == []
    assert File.exists?(Path.join(projects, "-tmp-proj/fresh.jsonl"))
  end

  test "quiescent trivial sessions are ledgered without a claude call", %{projects: projects} do
    write_session(projects, "tiny", ["hi"], iso_hours_ago(72))

    report = Sweep.run()

    assert report.trivial == 1
    assert report.results == []
    # transcript is left in place — trivial sessions are skipped, not consumed
    assert File.exists?(Path.join(projects, "-tmp-proj/tiny.jsonl"))
    assert [%{"outcome" => "trivial", "id" => "tiny"}] = Sweep.recent()
  end

  test "a trivial verdict is idempotent until the session gains messages", %{projects: projects} do
    write_session(projects, "tiny", ["hi"], iso_hours_ago(72))

    assert Sweep.run().trivial == 1
    assert Sweep.run().trivial == 0

    # new activity (a changed updated_at) re-arms the session
    write_session(projects, "tiny", ["hi", "more"], iso_hours_ago(60))
    assert Sweep.run().trivial == 1
  end

  test "quiescent non-trivial sessions are due but capped by max: 0", %{projects: projects} do
    write_session(projects, "real", ["a", "b", "c", "d", "e"], iso_hours_ago(72))

    # max: 0 exercises the due path without spending a claude call
    report = Sweep.run(max: 0)

    assert report.considered == 1
    assert report.deferred == 1
    assert report.results == []
    assert File.exists?(Path.join(projects, "-tmp-proj/real.jsonl"))
  end

  # ── dissolve queue ────────────────────────────────────────
  # Same claude-spend rule as above: no queue fixture may be both archived and
  # non-trivial unless the run is capped to max: 0.

  defp write_archive(log, id, messages) do
    dir = Path.join([log, "archive", "2026-07-13"])
    File.mkdir_p!(dir)

    lines =
      Enum.map(messages, fn text ->
        Jason.encode!(%{
          "type" => "user",
          "cwd" => "/tmp/proj",
          "timestamp" => "2026-07-13T00:00:00Z",
          "message" => %{"content" => text}
        })
      end)

    data = :zlib.gzip(Enum.join(lines, "\n") <> "\n")
    File.write!(Path.join(dir, id <> ".jsonl.gz"), data)
  end

  defp enqueue(id, opts \\ []) do
    entry = %{
      "id" => id,
      "cwd" => opts[:cwd] || "/tmp/proj",
      "title" => "t",
      "queued_at" => opts[:queued_at] || DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write!(Sweep.queue_path(), Jason.encode!(entry) <> "\n", [:append])
  end

  test "queued trivial sessions are consumed from the archive without a claude call",
       %{log: log} do
    write_archive(log, "qtiny", ["hi"])
    enqueue("qtiny")

    report = Sweep.run()

    assert [%{outcome: "trivial", id: "qtiny"}] = report.queue
    assert Sweep.queued() == []
    assert [%{"outcome" => "trivial", "source" => "queue"}] = Sweep.recent()
  end

  test "a queued entry with no archive yet waits and stays queued" do
    enqueue("flushing")

    report = Sweep.run()

    assert [%{outcome: "waiting"}] = report.queue
    assert [%{"id" => "flushing"}] = Sweep.queued()
    # waiting is not a ledger event — it would spam one line per hour
    assert Sweep.recent() == []
  end

  test "a queued entry whose archive never appears is lost after 24h" do
    enqueue("gone", queued_at: iso_hours_ago(25))

    report = Sweep.run()

    assert [%{outcome: "lost"}] = report.queue
    assert Sweep.queued() == []
    assert [%{"outcome" => "lost", "id" => "gone"}] = Sweep.recent()
  end

  test "a drain pass writes an inbox ledger line and populates report.inbox.outcomes",
       %{memory: memory} do
    Application.put_env(:orrery, :claude_runner, fn _prompt, _opts ->
      {:ok,
       %{output: %{"verdicts" => [%{"name" => "Inbox fact", "verdict" => "drop"}]}, cost: 0.0}}
    end)

    on_exit(fn -> Application.delete_env(:orrery, :claude_runner) end)

    staging = [
      %{
        "bank" => "-tmp-proj",
        "body" => "b",
        "description" => "d",
        "name" => "Inbox fact",
        "type" => "reference"
      }
    ]

    File.write!(Path.join(memory, ".staging.json"), Jason.encode!(staging))

    report = Sweep.run()

    assert report.inbox.dropped == 1
    assert [%{bank: "-tmp-proj", name: "Inbox fact", outcome: "dropped"}] = report.inbox.outcomes

    assert Enum.any?(Sweep.recent(), &(&1["source"] == "inbox" and &1["outcome"] == "inbox"))
  end

  test "queue entries count against the shared dissolve cap", %{
    log: log,
    projects: projects
  } do
    write_archive(log, "qreal", ["a", "b", "c", "d", "e"])
    enqueue("qreal")
    write_session(projects, "idle", ["a", "b", "c", "d", "e"], iso_hours_ago(72))

    # max: 0 → neither the queued nor the idle session may spend a claude call
    report = Sweep.run(max: 0)

    assert report.queue == []
    assert report.deferred == 1
    assert [%{"id" => "qreal"}] = Sweep.queued()
  end
end
