defmodule OrreryWeb.BoardLiveTest do
  use OrreryWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Orrery.Memory
  alias Orrery.Memory.Pipeline
  alias Orrery.Memory.Pipeline.Runner

  @project "-tmp-proj"
  @bank "-tmp-proj"

  # Isolate the memory / projects / log roots at fresh tmp dirs so the board renders
  # against an empty world instead of the live ~/.claude tree (mirrors memories_live_test).
  setup do
    base = Path.join(System.tmp_dir!(), "board_live_#{System.unique_integer([:positive])}")
    memory = Path.join(base, "memory")
    projects = Path.join(base, "projects")
    log = Path.join(base, "log")
    File.mkdir_p!(memory)
    File.mkdir_p!(Path.join(projects, @project))
    File.mkdir_p!(Path.join(log, "archive"))
    Application.put_env(:orrery, :memory_root, memory)
    Application.put_env(:orrery, :projects_dir, projects)
    Application.put_env(:orrery, :log_root, log)

    # A guard: the trivial sessions below never reach a claude call, but stub the seam so
    # nothing can ever shell out to the real CLI during a test.
    Application.put_env(:orrery, :claude_runner, fn _prompt, _opts ->
      {:ok, %{output: %{"memories" => []}, cost: 0.0}}
    end)

    on_exit(fn ->
      Application.delete_env(:orrery, :memory_root)
      Application.delete_env(:orrery, :projects_dir)
      Application.delete_env(:orrery, :log_root)
      Application.delete_env(:orrery, :claude_runner)
      File.rm_rf!(base)
    end)

    # A fresh, isolated Task.Supervisor + worker under the app's default names (the app
    # starts neither in :test). Registered AFTER the env `on_exit` so ExUnit tears them
    # down FIRST (LIFO): an in-flight dissolve task is killed before `memory_root` reverts,
    # so a trivial-session write can never land in the real ~/.claude ledger. The LiveView
    # dissolves through the default-named Pipeline.
    start_supervised!({Task.Supervisor, name: Orrery.Memory.Pipeline.TaskSup})
    start_supervised!(Pipeline)

    %{}
  end

  # ── helpers ───────────────────────────────────────────────
  # A live transcript under projects_dir — two non-prefix user turns (message_count 2,
  # below the 4-message trivial threshold, so a dissolve never calls claude).
  defp write_session(id, texts) do
    lines =
      Enum.map(texts, fn t ->
        Jason.encode!(%{
          "type" => "user",
          "cwd" => "/tmp/proj",
          "timestamp" => "2026-07-13T00:00:00Z",
          "message" => %{"content" => t}
        })
      end)

    File.write!(
      Path.join([Application.get_env(:orrery, :projects_dir), @project, id <> ".jsonl"]),
      Enum.join(lines, "\n") <> "\n"
    )
  end

  # Drop a candidate straight into the staging queue, as an extraction awaiting the judge.
  defp stage(name) do
    File.write!(
      Path.join(Memory.memory_root(), ".staging.json"),
      Jason.encode!([
        %{
          "bank" => @bank,
          "body" => "body of #{name}",
          "description" => "one-liner for #{name}",
          "name" => name,
          "recall" => nil,
          "replaces" => nil,
          "source" => "some session",
          "type" => "reference"
        }
      ])
    )
  end

  defp queue_lines do
    case File.read(Runner.queue_path()) do
      {:ok, txt} -> txt |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  # ── tests ─────────────────────────────────────────────────
  test "mounts and renders the five kanban columns", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for label <- ~w(LIVE QUEUED PROCESSING STAGED COMMITTED) do
      assert has_element?(view, ".col-head", label)
    end
  end

  test "a live session renders as a card in the LIVE column", %{conn: conn} do
    write_session("sess-a", ["hello alpha", "goodbye beta"])

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#live-#{@project}-sess-a")
  end

  test "dissolve enqueues exactly one queue line and drops the card from LIVE", %{conn: conn} do
    write_session("sess-b", ["hello alpha", "goodbye beta"])

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#live-#{@project}-sess-b")

    view
    |> element("#live-#{@project}-sess-b button[phx-click='dissolve']")
    |> render_click()

    assert queue_lines() == 1
    refute has_element?(view, "#live-#{@project}-sess-b")
  end

  test "a double dissolve still writes only one queue line", %{conn: conn} do
    write_session("sess-c", ["hello alpha", "goodbye beta"])

    {:ok, view, _html} = live(conn, ~p"/")

    params = %{"project" => @project, "id" => "sess-c", "title" => "sess-c"}
    render_click(view, "dissolve", params)
    render_click(view, "dissolve", params)

    assert queue_lines() == 1
  end

  test "approving a staged card commits it and disables the card's buttons", %{conn: conn} do
    stage("AlphaFact")

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ".col .card.mem", "AlphaFact")

    view
    |> element("button[phx-click='approve'][phx-value-name='AlphaFact']")
    |> render_click()

    # The in-flight guard disables the staged card's controls until `:memory_changed`.
    assert has_element?(view, "button[phx-click='approve'][disabled]")
    # The commit landed on disk (the memory is now a committed, non-staged file).
    assert Enum.any?(Memory.recent_committed(10), &(&1.name == "AlphaFact"))
  end

  test "opening a live card reveals the transcript in the drawer", %{conn: conn} do
    write_session("sess-d", ["drawer probe text", "second turn"])

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#live-#{@project}-sess-d") |> render_click()

    assert has_element?(view, "div[role='dialog']")
    assert has_element?(view, ".drawer .thread")
    assert render(view) =~ "drawer probe text"
  end

  test "a session_changed broadcast inserts a new live card, then removes it, without remount",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#live-#{@project}-sess-e")

    # A new on-disk session announced over PubSub streams into LIVE without a remount.
    write_session("sess-e", ["fresh session", "second turn"])
    Phoenix.PubSub.broadcast(Orrery.PubSub, "transcripts", {:session_changed, @project, "sess-e"})
    _ = render(view)
    assert has_element?(view, "#live-#{@project}-sess-e")

    # Its removal from disk, announced the same way, drops the card.
    File.rm!(Path.join([Application.get_env(:orrery, :projects_dir), @project, "sess-e.jsonl"]))
    Phoenix.PubSub.broadcast(Orrery.PubSub, "transcripts", {:session_changed, @project, "sess-e"})
    _ = render(view)
    refute has_element?(view, "#live-#{@project}-sess-e")
  end
end
