defmodule OrreryWeb.MemoriesLiveTest do
  use OrreryWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Orrery.Memory
  alias Orrery.Memory.Pipeline

  @bank "-tmp-proj"

  # Isolate the memory / projects / log roots at fresh tmp dirs so the browser renders
  # against an empty world instead of the live ~/.claude tree (mirrors pages_smoke_test).
  setup do
    base = Path.join(System.tmp_dir!(), "memories_live_#{System.unique_integer([:positive])}")
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
      File.rm_rf!(base)
    end)

    # The app starts no Pipeline in :test; these tests drive it via `Pipeline.status/0` and
    # `:sys.replace_state/2` (`with_busy_pipeline`), so start an isolated one under the
    # default name (torn down per test). No dissolve task runs — `request_*` fire only while
    # busy, so they short-circuit with `{:error, :busy}` before any Task is spawned.
    start_supervised!(Pipeline)

    %{memory: memory}
  end

  defp commit(name) do
    Memory.commit_memory(%{
      bank: @bank,
      body: "body of #{name}",
      description: "one-liner for #{name}",
      name: name,
      recall: nil,
      replaces: nil,
      source: nil,
      type: "reference"
    })
  end

  defp queue_lines do
    case File.read(Orrery.Memory.Pipeline.Runner.queue_path()) do
      {:ok, txt} -> txt |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  # Force the app-started singleton worker into a non-idle job so `request_*` refuse with
  # `{:error, :busy}`, then hand it back to idle — no claude call, fully deterministic.
  defp with_busy_pipeline(fun) do
    :sys.replace_state(Pipeline, &%{&1 | job: :sweep})

    try do
      fun.()
    after
      :sys.replace_state(Pipeline, &%{&1 | job: :idle})
    end
  end

  test "MemoriesLive never triggers a dissolve on mount (legacy entry point retired)",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/memories")

    assert html =~ "Memory Banks"
    # The old mount branch would have enqueued a dissolve; nothing runs and no line lands.
    assert Pipeline.status().job == :idle
    assert queue_lines() == 0
    refute render(view) =~ "Dissolving via claude"
  end

  test "bank browsing renders committed memory cards", %{conn: conn} do
    commit("AlphaFact")
    commit("BetaFact")

    {:ok, view, _html} = live(conn, ~p"/memories")

    assert has_element?(view, ".memory-name", "AlphaFact")
    assert has_element?(view, ".memory-name", "BetaFact")
  end

  test "dream while the pipeline is busy shows the busy banner", %{conn: conn} do
    commit("AlphaFact")
    commit("BetaFact")

    {:ok, view, _html} = live(conn, "/memories?bank=" <> @bank)

    with_busy_pipeline(fn ->
      html = view |> element("button[phx-click='dream']") |> render_click()
      assert html =~ "pipeline is busy"
    end)
  end

  test "merge while the pipeline is busy shows the busy banner", %{conn: conn} do
    commit("AlphaFact")
    commit("BetaFact")

    {:ok, view, _html} = live(conn, "/memories?bank=" <> @bank)

    # Select both committed memories (≥2 is the merge threshold), then fire merge while busy.
    files =
      Memory.list_banks()
      |> Enum.find(&(&1.id == @bank))
      |> Map.fetch!(:memories)
      |> Enum.reject(&(&1[:staged] == true))
      |> Enum.map(& &1.file)

    for f <- files, do: render_click(view, "toggle", %{"file" => f})

    with_busy_pipeline(fn ->
      html = render_click(view, "merge", %{})
      assert html =~ "pipeline is busy"
    end)
  end
end
