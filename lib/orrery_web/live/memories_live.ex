defmodule OrreryWeb.MemoriesLive do
  use OrreryWeb, :live_view
  import OrreryWeb.UI
  import OrreryWeb.MemoryComponents
  alias Orrery.Memory
  alias Orrery.Memory.Pipeline

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Orrery.PubSub, "memory")
      Pipeline.subscribe()
    end

    socket =
      socket
      |> assign(
        page_title: "Memory",
        editing: nil,
        selected: MapSet.new(),
        busy: nil,
        dream: nil,
        active_id: preselect(params["bank"]),
        show_archive: false
      )
      |> reload()

    {:ok, socket}
  end

  # ?bank= is a plain read-only preselect — component-guarded so a crafted value can't
  # point the browser at anything outside a bank id.
  defp preselect(b) when is_binary(b), do: (Orrery.Store.component?(b) && b) || nil
  defp preselect(_), do: nil

  defp reload(socket) do
    banks = Memory.list_banks()
    active = socket.assigns[:active_id] || (List.first(banks) && List.first(banks).id)

    socket
    |> assign(banks: banks, active_id: active)
    |> reload_archive()
  end

  defp reload_archive(%{assigns: %{show_archive: true, active_id: id}} = socket)
       when is_binary(id),
       do: assign(socket, archived: Memory.archived_memories(id))

  defp reload_archive(socket), do: assign(socket, archived: [])

  defp active_bank(%{banks: banks, active_id: id}),
    do: Enum.find(banks, &(&1.id == id)) || List.first(banks)

  defp staged(bank), do: Enum.filter(bank.memories, &(&1[:staged] == true))
  defp committed(bank), do: Enum.reject(bank.memories, &(&1[:staged] == true))

  # ── events ────────────────────────────────────────────────
  @impl true
  def handle_event("select_bank", %{"id" => id}, socket),
    do:
      {:noreply,
       assign(socket,
         active_id: id,
         selected: MapSet.new(),
         editing: nil,
         show_archive: false,
         archived: []
       )}

  def handle_event("edit", %{"name" => name}, socket) do
    # The memory can vanish between render and click (a watch-reload, another tab, or a
    # pipeline job that just re-staged) — Map.put(nil, …) would crash the socket.
    case Enum.find(active_bank(socket.assigns).memories, &(&1.name == name)) do
      nil ->
        {:noreply, socket}

      memory ->
        {:noreply, assign(socket, editing: Map.put(memory, :staged, memory[:staged] == true))}
    end
  end

  def handle_event("cancel_edit", _, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save", params, socket) do
    memory = %{
      bank: params["bank"],
      body: params["body"],
      description: params["description"],
      name: params["name"],
      recall: recall_for(params["recall"]),
      replaces: replaces_for(params),
      source: blank_to_nil(params["source"]),
      type: params["type"]
    }

    Memory.commit_memory(memory)
    {:noreply, socket |> assign(editing: nil) |> reload()}
  end

  def handle_event("delete", %{"file" => file}, socket) do
    Memory.delete_memory(active_bank(socket.assigns).id, file)
    {:noreply, reload(socket)}
  end

  def handle_event("toggle", %{"file" => file}, socket) do
    sel = socket.assigns.selected

    {:noreply,
     assign(socket,
       selected:
         if(MapSet.member?(sel, file), do: MapSet.delete(sel, file), else: MapSet.put(sel, file))
     )}
  end

  # Merge and dream route through the Pipeline so the claude pass survives a browser
  # disconnect; `{:error, :busy}` (a queue batch or another job holds the worker) surfaces
  # in the same banner. The result lands as a `{:pipeline, :job, {:finished, …}}` event.
  def handle_event("merge", _, socket) do
    bank = active_bank(socket.assigns)
    files = MapSet.to_list(socket.assigns.selected)

    case Pipeline.request_merge(bank.id, files) do
      :ok ->
        {:noreply, assign(socket, busy: "Merging via claude…", selected: MapSet.new())}

      {:error, :busy} ->
        {:noreply, assign(socket, busy: busy_msg())}
    end
  end

  def handle_event("dream", _, socket) do
    bank = active_bank(socket.assigns)

    case Pipeline.request_dream(bank.id) do
      :ok -> {:noreply, assign(socket, busy: "Dreaming #{bank.label} via claude…")}
      {:error, :busy} -> {:noreply, assign(socket, busy: busy_msg())}
    end
  end

  def handle_event("toggle_archive", _, socket) do
    {:noreply,
     socket |> assign(show_archive: not socket.assigns.show_archive) |> reload_archive()}
  end

  def handle_event("restore", %{"file" => file}, socket) do
    Memory.restore_memory(active_bank(socket.assigns).id, file)
    {:noreply, reload(socket)}
  end

  def handle_event("open_dream", _, socket),
    do: {:noreply, assign(socket, dream: Memory.get_dream())}

  def handle_event("close_dream", _, socket), do: {:noreply, assign(socket, dream: nil)}

  def handle_event("save_dream", %{"text" => text}, socket) do
    Memory.set_dream(text)
    {:noreply, assign(socket, dream: nil)}
  end

  # ── pipeline / watcher events ─────────────────────────────
  @impl true
  def handle_info({:pipeline, :job, {:finished, :merge, result}}, socket),
    do: {:noreply, socket |> assign(busy: merge_msg(result)) |> reload()}

  def handle_info({:pipeline, :job, {:finished, :dream, result}}, socket),
    do: {:noreply, socket |> assign(busy: dream_msg(result)) |> reload()}

  # Queue/entry progress, job-started, files_changed and every other pipeline event are
  # the board's concern — here they only ever mean "something moved", handled by the
  # Watcher's `:memory_changed` reload below.
  def handle_info({:pipeline, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pipeline, _}, socket), do: {:noreply, socket}

  def handle_info(:memory_changed, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp busy_msg,
    do: "The pipeline is busy — a dissolve or another job is running. Try again in a moment."

  defp merge_msg({:ok, {:ok, merged}}),
    do: "Merged #{length(merged.replaces)} memories into “#{merged.name}” — sources archived."

  defp merge_msg({:ok, {:error, :need_two}}),
    do: "Merge needs at least two memories that still exist."

  defp merge_msg({:ok, {:error, reason}}),
    do: "Merge failed (#{inspect(reason)}) — nothing changed."

  defp merge_msg(other), do: "Merge failed (#{inspect(other)}) — nothing changed."

  defp dream_msg({:ok, result}) do
    cond do
      result.error -> "Dream failed (#{inspect(result.error)}) — nothing changed."
      result.ops == [] -> "Dream: no ops — the bank is already sharp."
      true -> "Dream: #{length(result.ops)} op(s) applied."
    end
  end

  defp dream_msg(other), do: "Dream failed (#{inspect(other)}) — nothing changed."

  # `replaces_for/1`, `blank_to_nil/1`, `recall_for/1` are imported from MemoryComponents.

  # ── render ────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    active = active_bank(assigns)
    by_kind = Enum.group_by(assigns.banks, & &1.kind)

    bank_groups =
      for {kind, label} <- [
            managed: "Managed · dissolved",
            auto: "Auto · Claude Code (read-only)"
          ],
          group = Map.get(by_kind, kind, []),
          group != [],
          do: {label, group}

    assigns =
      assign(assigns,
        active: active,
        active_committed: (active && committed(active)) || [],
        bank_groups: bank_groups
      )

    ~H"""
    <div class="app">
      <.rail active={:memories} />

      <div class="sidebar">
        <header>
          <h1>Memory Banks</h1>
        </header>
        <div class="bank-actions">
          <button class="btn wide" phx-click="open_dream">
            <.ph name="moon-stars" /> Dream instructions
          </button>
        </div>
        <div class="list">
          <div :for={{label, group} <- @bank_groups}>
            <div class="group-label">{label}</div>
            <div
              :for={b <- group}
              class={["item", @active && @active.id == b.id && "active"]}
              phx-click="select_bank"
              phx-value-id={b.id}
              title={b.label}
            >
              <div class="title">{b.label}</div>
              <div class="meta">
                <span>{length(committed(b))} memories</span>
                <% pend = length(staged(b)) %>
                <.link
                  :if={pend > 0}
                  navigate={~p"/"}
                  class="tag staged-count"
                  title="Pending dissolves — open the board"
                >{pend} pending</.link>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="main">
        <div class="bar">
          <h2>{(@active && @active.label) || "Memory"}</h2>
          <span class="tag">{if @active && @active.readonly,
            do: "auto · Claude Code · read-only",
            else: "managed · you steer this"}</span>
          <span :if={@active} class="tag">{length(@active_committed)} memories</span>
          <button
            :if={@active && !@active.readonly && MapSet.size(@selected) >= 2}
            class="btn ok"
            phx-click="merge"
            data-confirm={"Merge #{MapSet.size(@selected)} memories into one? Sources are archived, recoverable."}
          >
            <.ph name="arrows-merge" /> merge {MapSet.size(@selected)}
          </button>
          <button
            :if={@active && !@active.readonly && length(@active_committed) >= 2}
            class="btn"
            phx-click="dream"
            title="One claude pass: merge/rewrite/archive ops, never grows the bank"
          >
            <.ph name="arrows-in-line-vertical" /> dream
          </button>
        </div>
        <div :if={@busy} class="banner">{@busy}</div>

        <div class="transcript">
          <div class="thread mem">
            <div :if={@active && @active_committed == []} class="empty-mem">
              {if @active.readonly,
                do: "This auto-memory bank is empty.",
                else: "This bank is empty. Dissolve a conversation to populate it."}
            </div>

            <%= if @active do %>
              <%= for f <- @active_committed do %>
                <.memory_editor :if={editing?(@editing, f)} memory={@editing} />
                <.memory_card
                  :if={!editing?(@editing, f)}
                  memory={f}
                  mode={if @active.readonly, do: :readonly, else: :committed}
                  selected={MapSet.member?(@selected, f.file)}
                />
              <% end %>
            <% end %>

            <div :if={@active && !@active.readonly} class="stage">
              <button class="btn" phx-click="toggle_archive">
                <.ph name={if @show_archive, do: "caret-down", else: "caret-right"} />
                Archive — superseded &amp; deleted, recoverable
              </button>
              <div :if={@show_archive}>
                <div :if={@archived == []} class="empty-mem">Nothing archived in this bank.</div>
                <.archived_card :for={a <- @archived} memory={a} />
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@dream} class="modal-bg">
        <div class="modal" phx-click-away="close_dream">
          <h3>Dream instructions</h3>
          <p class="hint">
            Guides every dissolve. The whole conversation is always fed — these tune what's kept.
          </p>
          <form phx-submit="save_dream">
            <textarea name="text" rows="16">{@dream}</textarea>
            <div class="f-actions">
              <button type="button" class="btn" phx-click="close_dream">cancel</button>
              <button type="submit" class="btn ok">save</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp editing?(nil, _f), do: false
  defp editing?(e, f), do: e[:staged] != true and e.file == f.file
end
