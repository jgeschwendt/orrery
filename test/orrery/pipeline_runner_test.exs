defmodule Orrery.Memory.Pipeline.RunnerTest do
  use ExUnit.Case, async: false

  alias Orrery.Memory.Pipeline.Runner

  setup do
    base = Path.join(System.tmp_dir!(), "runner_test_#{System.unique_integer([:positive])}")
    memory = Path.join(base, "memory")
    projects = Path.join(base, "projects")
    log = Path.join(base, "log")
    File.mkdir_p!(memory)
    File.mkdir_p!(projects)
    File.mkdir_p!(Path.join(log, "archive"))
    Application.put_env(:orrery, :memory_root, memory)
    Application.put_env(:orrery, :projects_dir, projects)
    Application.put_env(:orrery, :log_root, log)

    on_exit(fn ->
      Application.delete_env(:orrery, :memory_root)
      Application.delete_env(:orrery, :projects_dir)
      Application.delete_env(:orrery, :log_root)
      Application.delete_env(:orrery, :claude_runner)
      File.rm_rf!(base)
    end)

    %{log: log}
  end

  # ── helpers ───────────────────────────────────────────────
  defp queue_line(map),
    do: File.write!(Runner.queue_path(), Jason.encode!(map) <> "\n", [:append])

  defp queue_raw(text), do: File.write!(Runner.queue_path(), text, [:append])

  defp ledger_line(map),
    do: File.write!(Runner.ledger_path(), Jason.encode!(map) <> "\n", [:append])

  defp entry(id, opts \\ []) do
    %{
      "id" => id,
      "cwd" => opts[:cwd] || "/tmp/proj",
      "title" => opts[:title] || "t",
      "queued_at" => opts[:queued_at] || DateTime.to_iso8601(DateTime.utc_now())
    }
  end

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

  defp stub_claude do
    Application.put_env(:orrery, :claude_runner, fn prompt, _opts ->
      if String.contains?(prompt, "memory-quality judge") do
        {:ok, %{output: %{"verdicts" => [%{"name" => "Fact", "verdict" => "drop"}]}, cost: 0.0}}
      else
        {:ok,
         %{
           output: %{
             "memories" => [
               %{"name" => "Fact", "description" => "d", "type" => "reference", "body" => "b"}
             ]
           },
           cost: 0.0
         }}
      end
    end)
  end

  defp iso_hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h * 3600) |> DateTime.to_iso8601()

  # ── pending derivation ────────────────────────────────────
  test "dedup by id keeps the first occurrence" do
    queue_line(entry("d", title: "first"))
    queue_line(entry("d", title: "second"))

    assert [%{"id" => "d", "title" => "first"}] = Runner.pending()
  end

  test "an id with a permanent ledger outcome is excluded" do
    queue_line(entry("p"))
    ledger_line(%{"id" => "p", "outcome" => "staged"})

    assert Runner.pending() == []
  end

  test "an error-ledgered id stays pending with attempts and last_error" do
    queue_line(entry("e"))
    ledger_line(%{"id" => "e", "outcome" => "error", "error" => "boom1"})
    ledger_line(%{"id" => "e", "outcome" => "error", "error" => "boom2"})

    assert [%{"id" => "e", "attempts" => 2, "last_error" => "boom2"}] = Runner.pending()
  end

  test "a partially-flushed trailing queue line is skipped" do
    queue_line(entry("a"))
    # a shell append can leave the last line truncated mid-write
    queue_raw(~s({"id":"b","cwd":"/tmp/pr))

    assert [%{"id" => "a"}] = Runner.pending()
  end

  test "a historical ledger line with no project still excludes its id" do
    queue_line(entry("h"))
    # pre-`project` ledger lines lack "project"; an {project, id} key would miss this
    ledger_line(%{"id" => "h", "outcome" => "dissolved"})

    assert Runner.pending() == []
  end

  # ── process_entry outcomes ────────────────────────────────
  test "no archive yet, young entry → waiting (not ledgered)" do
    result = Runner.process_entry(entry("flushing"))

    assert %{outcome: "waiting"} = result
    assert Runner.ledger() == %{}
  end

  test "no archive after 24h → lost (permanent)" do
    result = Runner.process_entry(entry("gone", queued_at: iso_hours_ago(25)))

    assert %{outcome: "lost"} = result
    assert %{"gone" => %{"outcome" => "lost"}} = Runner.ledger()
  end

  test "an archived sub-4-message session → trivial with no claude call", %{log: log} do
    write_archive(log, "tiny", ["hi"])

    result = Runner.process_entry(entry("tiny"))

    assert %{outcome: "trivial"} = result
    assert Runner.pending() == []
  end

  test "an archived non-trivial session distills to dissolved", %{log: log} do
    stub_claude()
    write_archive(log, "qreal", ["a", "b", "c", "d", "e"])
    queue_line(entry("qreal"))

    result = Runner.process_entry(entry("qreal"))

    assert %{outcome: "dissolved"} = result
    # dissolved is permanent — the ledgered outcome removes it from pending
    assert Runner.pending() == []
    assert %{"qreal" => %{"outcome" => "dissolved", "project" => "-tmp-proj"}} = Runner.ledger()
  end

  test "progress fires :extracting then :judging on the real distill path", %{log: log} do
    stub_claude()
    write_archive(log, "qreal", ["a", "b", "c", "d", "e"])
    parent = self()

    Runner.process_entry(entry("qreal"), DateTime.utc_now(), &send(parent, {:progress, &1}))

    assert_receive {:progress, :extracting}
    assert_receive {:progress, :judging}
  end
end
