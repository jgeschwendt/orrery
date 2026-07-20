defmodule OrreryWeb.RoutinesLive do
  use OrreryWeb, :live_view
  import OrreryWeb.UI
  alias Orrery.Routines

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, :tick)

    {:ok,
     socket |> assign(busy: nil, modal: nil, page_title: "Routines", selected: nil) |> load()}
  end

  defp load(socket) do
    routines = Routines.list()
    selected = socket.assigns[:selected] || (List.first(routines) || %{})["slug"]
    assign(socket, routines: routines, selected: selected)
  end

  defp selected_routine(%{routines: rs, selected: s}),
    do: Enum.find(rs, &(&1["slug"] == s)) || List.first(rs)

  # ── events ────────────────────────────────────────────────
  @impl true
  def handle_event("select", %{"slug" => slug}, socket),
    do: {:noreply, assign(socket, selected: slug)}

  def handle_event("new", _, socket),
    do:
      {:noreply,
       assign(socket,
         busy: nil,
         modal: %{mode: :new, params: Routines.new_form_params(), slug: nil}
       )}

  def handle_event("edit", _, socket) do
    r = selected_routine(socket.assigns)

    {:noreply,
     assign(socket,
       busy: nil,
       modal: %{mode: :edit, params: Routines.to_form_params(r), slug: r["slug"]}
     )}
  end

  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("draft", params, socket) do
    merged = Map.merge(socket.assigns.modal.params, Map.drop(params, ["_target"]))
    {:noreply, assign(socket, modal: %{socket.assigns.modal | params: merged})}
  end

  def handle_event("save", params, socket) do
    modal = socket.assigns.modal

    result =
      if modal.mode == :new,
        do: Routines.create(params),
        else: Routines.update(modal.slug, params)

    case result do
      {:ok, r} ->
        {:noreply,
         socket
         |> assign(busy: "Saved “#{r["name"]}”.", modal: nil, selected: r["slug"])
         |> load()}

      {:error, e} ->
        {:noreply, assign(socket, busy: "Error: #{e}", modal: %{modal | params: params})}
    end
  end

  def handle_event("run_now", %{"slug" => slug}, socket) do
    msg =
      if Routines.run_now(slug) == :ok,
        do: "Triggered — output streams into the log below.",
        else: "Error triggering run."

    {:noreply, socket |> assign(busy: msg) |> load()}
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    Routines.delete(slug)
    {:noreply, socket |> assign(busy: "Routine removed.", selected: nil) |> load()}
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  # ── render ────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    active = selected_routine(assigns)
    assigns = assign(assigns, active: active, log: active && Routines.log_tail(active["slug"]))

    ~H"""
    <div class="app">
      <.rail active={:routines} />

      <div class="sidebar">
        <header>
          <h1>Routines</h1>
        </header>
        <div class="bank-actions">
          <button class="btn wide" phx-click="new"><.ph name="plus" /> New routine</button>
        </div>
        <div class="list">
          <div
            :for={r <- @routines}
            class={["item", @active && @active["slug"] == r["slug"] && "active"]}
            phx-click="select"
            phx-value-slug={r["slug"]}
            title={r["name"]}
          >
            <div class="title">
              <span class={["dot", r["loaded"] && "on"]} /> {r["name"]}
            </div>
            <div class="meta">
              <span>{Routines.schedule_label(r["schedule"])}</span>
              <span :if={r["last_run"]}>· last exit {r["last_run"]["exit"]}</span>
            </div>
          </div>
        </div>
      </div>

      <div class="main">
        <%= if @active do %>
          <div class="bar">
            <h2>{@active["name"]}</h2>
            <span class="tag">{Routines.schedule_label(@active["schedule"])}</span>
            <span class="tag">{if @active["loaded"], do: "loaded in launchd", else: "not loaded"}</span>
            <span class="tag">{(@active["last_run"] && @active["last_run"]["finished"]) || "never run"}</span>
            <button class="btn ok" phx-click="run_now" phx-value-slug={@active["slug"]}><.ph name="play" />
            run now</button>
            <button class="btn" phx-click="edit"><.ph name="pencil-simple" /> edit</button>
            <button
              class="btn warn"
              phx-click="delete"
              phx-value-slug={@active["slug"]}
              data-confirm={"Delete “#{@active["name"]}”? Its launchd agent will be removed."}
            >
              <.ph name="trash" /> delete
            </button>
            <button class="btn dissolve" phx-click="refresh"><.ph name="arrows-clockwise" /> refresh</button>
          </div>

          <div :if={@busy} class="banner">{@busy}</div>

          <div class="transcript">
            <div class="thread mem">
              <details class="tool">
                <summary>
                  <.ph name="caret-right" class="chev" />
                  <span class="name">{if @active["command"], do: "command", else: "prompt"}</span>
                  <span class="summary">
                    {if @active["command"],
                      do: "shell command, runs as-is",
                      else: "what claude runs, unattended"}
                  </span>
                </summary>
                <pre>{@active["command"] || @active["prompt"]}</pre>
              </details>

              <details class="tool" open style="margin-top:12px">
                <summary>
                  <.ph name="caret-right" class="chev" />
                  <span class="name">{@active["slug"]}.log</span>
                  <span class="summary">{Routines.log_path(@active["slug"])}</span>
                </summary>
                <pre>{log_or_empty(@log)}</pre>
              </details>
            </div>
          </div>
        <% else %>
          <div class="empty">No routines yet. Press “New routine” to add one.</div>
        <% end %>
      </div>

      <div :if={@modal} class="modal-bg" phx-click="close_modal">
        <div class="modal wide-modal" onclick="event.stopPropagation()">
          <h3>{if @modal.mode == :new, do: "New routine", else: "Edit routine"}</h3>
          <p class="hint">
            launchd runs this on the schedule below, unattended — claude gets <code>--permission-mode=auto</code>.
          </p>

          <form phx-change="draft" phx-submit="save">
            <input name="name" value={@modal.params["name"]} placeholder="name (e.g. Update tools)" />

            <input
              name="schedule"
              value={@modal.params["schedule"]}
              placeholder="every 6h · 0 9 * * * · 0 9-17 * * 1-5 · */30 9-17 * * mon-fri"
            />
            <% hint = schedule_hint(@modal.params["schedule"]) %>
            <span class={["hint", if(elem(hint, 0) == :ok, do: "hint-ok", else: "hint-err")]}>
              {elem(hint, 1)}
            </span>

            <textarea name="prompt" rows="12" placeholder="what claude should do, unattended">{@modal.params["prompt"]}</textarea>

            <input
              name="command"
              value={@modal.params["command"]}
              placeholder="…or a shell command instead (advanced — runs as-is, no claude)"
            />

            <div class="f-actions">
              <button type="button" class="btn" phx-click="close_modal">cancel</button>
              <button type="submit" class="btn ok">save</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp log_or_empty(""), do: "No runs yet. Press “run now” to trigger one."
  defp log_or_empty(log), do: log

  defp schedule_hint(str) do
    case Routines.parse_schedule_string(str) do
      {:error, e} -> {:err, "✗ #{e}"}
      sched -> {:ok, "↻ #{Routines.humanize_schedule(sched)}"}
    end
  end
end
