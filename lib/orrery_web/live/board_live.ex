defmodule OrreryWeb.BoardLive do
  @moduledoc """
  The kanban board: cards flow LIVE → QUEUED → PROCESSING → STAGED → COMMITTED as the
  `Orrery.Memory.Pipeline` worker drives each dissolve.

  ## Event-as-invalidation, snapshot-as-truth

  Every `{:pipeline, …}` handler re-queries `Pipeline.status/0` and re-partitions rather
  than mutating from the event payload — a replayed, duplicate, or missed event all
  converge, and a reconnect is identical to a fresh mount. Only the LIVE column is a
  stream (unbounded); QUEUED / PROCESSING / STAGED / outcome / COMMITTED are plain
  bounded assigns. Live-column membership is every session minus the pending ids
  (`status.queue` + the in-flight entry).
  """
  use OrreryWeb, :live_view
  import OrreryWeb.UI
  import OrreryWeb.BoardComponents
  import OrreryWeb.MemoryComponents
  alias Orrery.{Memory, Transcripts}
  alias Orrery.Memory.{Pipeline, Sweep}

  @committed_n 12
  @recent_n 12

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Pipeline.subscribe()
      Phoenix.PubSub.subscribe(Orrery.PubSub, "transcripts")
      Phoenix.PubSub.subscribe(Orrery.PubSub, "memory")
    end

    socket =
      socket
      |> assign(
        page_title: "Board",
        q: "",
        drawer: nil,
        banner: nil,
        live?: connected?(socket),
        staging_busy: MapSet.new()
      )
      |> stream_configure(:live, dom_id: fn %{project: p, id: id} -> "live-#{p}-#{id}" end)
      |> load()

    {:ok, socket}
  end

  # ── snapshot ──────────────────────────────────────────────
  defp load(socket) do
    socket
    |> assign_status(Pipeline.status())
    |> assign_memory()
    |> stream_live(reset: true)
  end

  defp assign_status(socket, status) do
    assign(socket,
      status: status,
      queue: status.queue,
      in_flight: status.in_flight,
      job: status.job
    )
  end

  # STAGED, the outcome cards atop COMMITTED (session outcomes only — inbox audit lines
  # carry no title/id), and the committed memories below them.
  defp assign_memory(socket) do
    assign(socket,
      staged: Memory.read_staging(),
      outcomes:
        Sweep.recent(@recent_n) |> Enum.filter(&(&1["outcome"] in ~w(dissolved staged trivial))),
      committed: Memory.recent_committed(@committed_n)
    )
  end

  # Re-partition LIVE from disk: every session minus the pending ids, honouring the search.
  defp stream_live(socket, opts) do
    pending = pending_ids(socket.assigns.status)

    live =
      Transcripts.list_sessions()
      |> Enum.reject(&MapSet.member?(pending, &1.id))
      |> filter_q(socket.assigns.q)

    stream(socket, :live, live, opts)
  end

  defp refresh_pipeline(socket) do
    socket |> assign_status(Pipeline.status()) |> stream_live(reset: true)
  end

  defp pending_ids(status) do
    ids = Enum.map(status.queue, & &1.id)
    ids = if status.in_flight, do: [status.in_flight.id | ids], else: ids
    MapSet.new(ids)
  end

  defp filter_q(sessions, ""), do: sessions

  defp filter_q(sessions, q) do
    needle = String.downcase(q)
    Enum.filter(sessions, &match_q?(&1, needle))
  end

  defp match_q?(_s, ""), do: true

  defp match_q?(s, needle) do
    String.contains?(String.downcase(s.title || ""), needle) or
      String.contains?(String.downcase(s.cwd || ""), needle)
  end

  # ── events: board bar ─────────────────────────────────────
  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: q) |> stream_live(reset: true)}

  def handle_event("sweep_now", _, socket) do
    banner =
      case Pipeline.request_sweep() do
        :ok -> "Sweep started — dissolving idle sessions, draining the inbox…"
        {:error, :busy} -> "A job is already running — nothing started."
      end

    {:noreply, assign(socket, banner: banner)}
  end

  # ── events: drawer ────────────────────────────────────────
  # A conversation opens its transcript: the live file first, else the @log archive the
  # dissolve already wrote, else the "consumed" empty state.
  def handle_event("open_card", %{"id" => id} = params, socket) do
    session =
      (params["project"] && params["project"] != "" &&
         Transcripts.get_session(params["project"], id)) || Transcripts.parse_archived(id)

    {:noreply, assign(socket, drawer: %{kind: :transcript, session: session})}
  end

  def handle_event("close_drawer", _, socket), do: {:noreply, assign(socket, drawer: nil)}
  def handle_event("cancel_edit", _, socket), do: {:noreply, assign(socket, drawer: nil)}

  # ── events: LIVE card actions ─────────────────────────────
  # `enqueue_session` is itself idempotent (it re-derives pending from disk), so a
  # double-click appends at most one queue line. The optimistic stream_delete gives
  # instant feedback; the `:queued` broadcast's re-partition confirms it.
  def handle_event("dissolve", %{"project" => p, "id" => id} = params, socket) do
    socket =
      if MapSet.member?(pending_ids(socket.assigns.status), id) do
        socket
      else
        Pipeline.enqueue_session(p, id, params["title"] || id)
        stream_delete_by_dom_id(socket, :live, "live-#{p}-#{id}")
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"project" => p, "id" => id}, socket) do
    unless MapSet.member?(pending_ids(socket.assigns.status), id),
      do: Transcripts.delete_session(p, id)

    {:noreply, stream_delete_by_dom_id(socket, :live, "live-#{p}-#{id}")}
  end

  # A retry re-kicks the worker: an errored entry is still pending (error is not a
  # permanent outcome), so the next pass reprocesses it.
  def handle_event("retry", _, socket) do
    Pipeline.kick()
    {:noreply, socket}
  end

  # ── events: STAGED card actions ───────────────────────────
  def handle_event("approve", %{"bank" => bank, "name" => name}, socket) do
    socket =
      case find_staged(socket, bank, name) do
        nil -> socket
        memory -> commit_and_flag(socket, memory, bank, name)
      end

    {:noreply, socket}
  end

  def handle_event("reject", %{"bank" => bank, "name" => name}, socket) do
    Memory.reject_staged(bank, name)
    {:noreply, flag_busy(socket, bank, name)}
  end

  def handle_event("edit", %{"bank" => bank, "name" => name}, socket) do
    socket =
      case find_staged(socket, bank, name) do
        nil -> socket
        memory -> assign(socket, drawer: %{kind: :editor, memory: Map.put(memory, :staged, true)})
      end

    {:noreply, socket}
  end

  # The drawer editor's commit path — mirrors MemoriesLive's `save`.
  def handle_event("save", params, socket) do
    Memory.commit_memory(%{
      bank: params["bank"],
      body: params["body"],
      description: params["description"],
      name: params["name"],
      recall: recall_for(params["recall"]),
      replaces: replaces_for(params),
      source: blank_to_nil(params["source"]),
      type: params["type"]
    })

    {:noreply, socket |> assign(drawer: nil) |> assign_memory()}
  end

  # `replaces_for/1`, `blank_to_nil/1`, `recall_for/1` are imported from MemoryComponents
  # (the editor's home) — shared with MemoriesLive's `save`.

  defp find_staged(socket, bank, name),
    do: Enum.find(socket.assigns.staged, &(&1.bank == bank and &1.name == name))

  defp commit_and_flag(socket, memory, bank, name) do
    Memory.commit_memory(memory)
    flag_busy(socket, bank, name)
  end

  defp flag_busy(socket, bank, name),
    do: assign(socket, staging_busy: MapSet.put(socket.assigns.staging_busy, {bank, name}))

  # ── pipeline / transcript / memory events ─────────────────
  # `{:done}` additionally refreshes the memory-side lanes (a new outcome + committed
  # cards); the rest just re-partition the queue/live snapshot.
  @impl true
  def handle_info({:pipeline, _id, {:done, _}}, socket),
    do: {:noreply, socket |> refresh_pipeline() |> assign_memory()}

  def handle_info({:pipeline, _id, {:error, _}}, socket),
    do: {:noreply, refresh_pipeline(socket)}

  def handle_info({:pipeline, :job, {:finished, _kind, _info}}, socket),
    do: {:noreply, socket |> refresh_pipeline() |> assign_memory() |> assign(banner: nil)}

  def handle_info({:pipeline, :job, _}, socket),
    do: {:noreply, refresh_pipeline(socket)}

  def handle_info({:pipeline, :files_changed}, socket),
    do: {:noreply, refresh_pipeline(socket)}

  def handle_info({:pipeline, _id, _stage}, socket),
    do: {:noreply, refresh_pipeline(socket)}

  # A transcript appeared/vanished: insert it into LIVE (unless pending or filtered out),
  # else drop it.
  def handle_info({:session_changed, p, id}, socket) do
    updated = Transcripts.get_session(p, id)
    pending = pending_ids(socket.assigns.status)

    socket =
      if updated && not MapSet.member?(pending, id) &&
           match_q?(updated, String.downcase(socket.assigns.q)) do
        stream_insert(socket, :live, Map.delete(updated, :messages), at: 0)
      else
        stream_delete_by_dom_id(socket, :live, "live-#{p}-#{id}")
      end

    {:noreply, socket}
  end

  # A file changed under the memory root (a commit / reject / staging write) — refresh the
  # memory lanes and clear the in-flight guards.
  def handle_info(:memory_changed, socket),
    do: {:noreply, socket |> assign_memory() |> assign(staging_busy: MapSet.new())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── render ────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    ~H"""
    <div class="app board-app" phx-window-keydown={@drawer && "close_drawer"} phx-key="Escape">
      <.rail active={:board} />

      <div class="main">
        <div class="board-bar">
          <form id="board-search" phx-change="search">
            <input
              class="search"
              name="q"
              value={@q}
              placeholder="Search live sessions…"
              phx-debounce="120"
            />
          </form>
          <span class="live"><span class={["dot", @live? && "on"]} />{if @live?,
            do: "live",
            else: "off"}</span>
          <button id="sweep-now" class="btn" phx-click="sweep_now" disabled={@job != :idle}>
            <.ph name="broom" /> sweep now
          </button>
          <span :if={@job == :sweep} class="tag">sweep running…</span>
        </div>

        <div :if={@banner} class="banner">{@banner}</div>

        <div class="board">
          <.board_column label="LIVE" body_id="live" stream empty="No live sessions">
            <.convo_card
              :for={{id, s} <- @streams.live}
              id={id}
              variant={:live}
              title={s.title}
              project={s.project}
              sid={s.id}
              cwd={s.cwd}
              at={s.updated_at}
              msgs={s.message_count}
              tokens={s.tokens.input + s.tokens.output}
            />
          </.board_column>

          <.board_column label="QUEUED" count={length(@queue)} empty="Nothing queued">
            <.convo_card
              :for={e <- @queue}
              variant={:queued}
              title={e.title || e.id}
              sid={e.id}
              cwd={e.cwd}
              at={e.queued_at}
              position={e.position}
              reason={e.last_error}
            />
          </.board_column>

          <.board_column label="PROCESSING" count={if @in_flight, do: 1, else: 0} empty="Idle">
            <.convo_card
              :if={@in_flight}
              variant={:processing}
              title={@in_flight.title || @in_flight.id}
              sid={@in_flight.id}
              at={@in_flight.started_at}
              stage={@in_flight.stage}
            />
          </.board_column>

          <.board_column label="STAGED" count={length(@staged)} empty="Inbox clear">
            <.memory_mini_card
              :for={m <- @staged}
              memory={m}
              staged
              busy={MapSet.member?(@staging_busy, {m.bank, m.name})}
            />
          </.board_column>

          <.board_column
            label="COMMITTED"
            count={length(@outcomes) + length(@committed)}
            empty="No memories yet"
          >
            <.outcome_card :for={e <- @outcomes} entry={e} />
            <.memory_mini_card :for={m <- @committed} memory={m} />
          </.board_column>
        </div>
      </div>

      <.drawer
        :if={@drawer}
        label={(@drawer.kind == :transcript && "Conversation transcript") || "Edit memory"}
      >
        <%= case @drawer.kind do %>
          <% :transcript -> %>
            <%= if @drawer.session do %>
              <h2>{@drawer.session.title}</h2>
              <div class="transcript">
                <div class="thread">
                  <.message
                    :for={m <- Enum.reject(@drawer.session.messages, & &1.is_meta)}
                    msg={m}
                  />
                </div>
              </div>
            <% else %>
              <div class="empty">This transcript was consumed by its dissolve.</div>
            <% end %>
          <% :editor -> %>
            <.memory_editor memory={@drawer.memory} />
        <% end %>
      </.drawer>
    </div>
    """
  end
end
