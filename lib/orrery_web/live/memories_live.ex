defmodule OrreryWeb.MemoriesLive do
  use OrreryWeb, :live_view
  import OrreryWeb.UI
  alias Orrery.{Memory, Transcripts}
  alias Orrery.Memory.Sweep

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orrery.PubSub, "memory")

    socket =
      socket
      |> assign(
        page_title: "Memory",
        editing: nil,
        selected: MapSet.new(),
        busy: nil,
        dream: nil,
        picker: nil,
        active_id: nil,
        show_archive: false,
        sweeping: false
      )
      |> reload()

    socket =
      with id when is_binary(id) <- params["dissolve"],
           true <- connected?(socket),
           [p, sid] <- String.split(id, "/", parts: 2) do
        start_dissolve(socket, p, sid)
      else
        _ -> socket
      end

    {:ok, socket}
  end

  defp reload(socket) do
    banks = Memory.list_banks()
    active = socket.assigns[:active_id] || (List.first(banks) && List.first(banks).id)

    socket
    |> assign(
      banks: banks,
      active_id: active,
      ledger: Orrery.Memory.Sweep.recent(8),
      queue: Orrery.Memory.Sweep.queued()
    )
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
    # The memory can vanish between render and click (a watch-reload, another tab, or an
    # async distill that just re-staged) — Map.put(nil, …) would crash the socket.
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

  def handle_event("approve", %{"name" => name}, socket) do
    bank = active_bank(socket.assigns)
    if f = Enum.find(staged(bank), &(&1.name == name)), do: Memory.commit_memory(f)
    {:noreply, reload(socket)}
  end

  def handle_event("reject", %{"name" => name}, socket) do
    Memory.reject_staged(active_bank(socket.assigns).id, name)
    {:noreply, reload(socket)}
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

  def handle_event("merge", _, socket) do
    bank = active_bank(socket.assigns)
    files = MapSet.to_list(socket.assigns.selected)

    {:noreply,
     socket
     |> assign(busy: "Merging via claude…", selected: MapSet.new())
     |> start_async(:merge, fn -> Memory.merge_memories(bank.id, files) end)}
  end

  def handle_event("toggle_archive", _, socket) do
    {:noreply,
     socket |> assign(show_archive: not socket.assigns.show_archive) |> reload_archive()}
  end

  def handle_event("restore", %{"file" => file}, socket) do
    Memory.restore_memory(active_bank(socket.assigns).id, file)
    {:noreply, reload(socket)}
  end

  def handle_event("sweep_now", _, socket) do
    {:noreply,
     socket
     |> assign(busy: "Sweeping — dissolving idle sessions, draining the inbox…", sweeping: true)
     |> start_async(:sweep, fn -> Orrery.Memory.Sweep.run() end)}
  end

  def handle_event("dream", _, socket) do
    bank = active_bank(socket.assigns)

    {:noreply,
     socket
     |> assign(busy: "Dreaming #{bank.label} via claude…")
     |> start_async(:dream, fn -> Orrery.Memory.Dream.run(bank.id) end)}
  end

  def handle_event("open_dream", _, socket),
    do: {:noreply, assign(socket, dream: Memory.get_dream())}

  def handle_event("close_dream", _, socket), do: {:noreply, assign(socket, dream: nil)}

  def handle_event("save_dream", %{"text" => text}, socket) do
    Memory.set_dream(text)
    {:noreply, assign(socket, dream: nil)}
  end

  # Sessions pre-marked archive-on-exit belong to the session-end machinery — offering
  # them here would consume a transcript that is about to archive itself.
  def handle_event("open_picker", _, socket),
    do:
      {:noreply,
       assign(socket,
         picker:
           Enum.reject(
             Transcripts.list_sessions(),
             &Orrery.Memory.Sweep.marked_archive_on_exit?(&1.id)
           )
       )}

  def handle_event("close_picker", _, socket), do: {:noreply, assign(socket, picker: nil)}

  def handle_event("distill", %{"project" => p, "id" => id}, socket),
    do: {:noreply, start_dissolve(socket, p, id)}

  # Distill the whole conversation, then compact-delete its source transcript
  # (consume-on-dissolve; the transcript is gzip-archived to the @log archive, not erased).
  # Guard first: project/id are client-controlled (URL param, phx-value) so reject path
  # traversal, and a stale list (or a non-persisted dream run) can point at a transcript
  # that's already gone — dissolving that would crash distill_session with "session not
  # found". Consume the transcript on any successful extraction (memories committed,
  # staged for a later judge, or a genuine clean zero); only an extraction *error*
  # leaves it in place for retry — same contract as Orrery.Memory.Sweep.
  defp start_dissolve(socket, project, id) do
    cond do
      not (Orrery.Store.component?(project) and Orrery.Store.component?(id)) or
          is_nil(Transcripts.get_session(project, id)) ->
        assign(socket,
          busy:
            "That conversation no longer exists — it may have been dissolved, deleted, or archived.",
          picker: nil
        )

      Orrery.Memory.Sweep.marked_archive_on_exit?(id) ->
        assign(socket,
          busy: "That session is ending on its own — its transcript will archive itself.",
          picker: nil
        )

      true ->
        socket
        |> assign(busy: "Dissolving via claude…", picker: nil)
        |> start_async(:distill, fn ->
          result = Memory.distill_session(project, id)
          if is_nil(result.error), do: Transcripts.delete_session(project, id)
          result
        end)
    end
  end

  # ── async (slow claude calls) ─────────────────────────────
  @impl true
  def handle_async(:distill, {:ok, result}, socket),
    do:
      {:noreply, socket |> assign(busy: distill_msg(result), active_id: result.bank) |> reload()}

  def handle_async(:merge, {:ok, result}, socket) do
    msg =
      case result do
        {:ok, merged} ->
          "Merged #{length(merged.replaces)} memories into “#{merged.name}” — sources archived."

        {:error, :need_two} ->
          "Merge needs at least two memories that still exist."

        {:error, reason} ->
          "Merge failed (#{inspect(reason)}) — nothing changed."
      end

    {:noreply, socket |> assign(busy: msg) |> reload()}
  end

  def handle_async(:sweep, {:ok, :locked}, socket),
    do:
      {:noreply,
       assign(socket, busy: "A sweep is already running — nothing started.", sweeping: false)}

  def handle_async(:sweep, {:ok, %{} = report}, socket) do
    msg = "Sweep: " <> Sweep.summary_line(report) <> "."
    {:noreply, socket |> assign(busy: msg, sweeping: false) |> reload()}
  end

  def handle_async(:dream, {:ok, result}, socket) do
    msg =
      cond do
        result.error -> "Dream failed (#{inspect(result.error)}) — nothing changed."
        result.ops == [] -> "Dream: no ops — the bank is already sharp."
        true -> "Dream: #{length(result.ops)} op(s) applied."
      end

    {:noreply, socket |> assign(busy: msg) |> reload()}
  end

  def handle_async(_, {:exit, reason}, socket),
    do: {:noreply, assign(socket, busy: "Error: #{inspect(reason)}", sweeping: false)}

  defp distill_msg(result) do
    cond do
      result[:error] ->
        "Extraction failed (#{inspect(result.error)}) — transcript kept; the sweep will retry."

      result[:staged] && result.staged > 0 ->
        "Judge unavailable — #{result.staged} candidate(s) staged for review."

      result.memories == [] ->
        "No durable memories found in that conversation."

      true ->
        "#{length(result.memories)} #{(length(result.memories) == 1 && "memory") || "memories"} committed" <>
          if(result[:dropped] && result.dropped > 0,
            do: " · #{result.dropped} dropped by the judge.",
            else: "."
          )
    end
  end

  @impl true
  def handle_info(:memory_changed, socket), do: {:noreply, reload(socket)}

  defp replaces_for(%{"staged" => "true", "replaces" => r}) when is_binary(r),
    do: Jason.decode!(r)

  defp replaces_for(%{"orig_file" => f}) when f not in [nil, ""], do: [f]
  defp replaces_for(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp recall_for(r) when r in ~w(pin index mute), do: r
  defp recall_for(_), do: nil

  # Updated within the last hour — the session may still be open in a terminal, and a
  # dissolve would consume its transcript out from under it. Confirm, don't forbid.
  defp recently_active?(%{updated_at: ts}) when is_binary(ts) and ts != "" do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt) < 3600
      _ -> false
    end
  end

  defp recently_active?(_), do: false

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
        active_staged: (active && staged(active)) || [],
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
          <button class="btn wide" phx-click="open_picker"><.ph name="drop" /> Dissolve a conversation</button>
          <button class="btn wide" phx-click="open_dream"><.ph name="moon-stars" /> Dream instructions</button>
          <button class="btn wide" phx-click="sweep_now" disabled={@sweeping}>
            <.ph name="broom" /> Sweep now
          </button>
        </div>
        <div class="list">
          <div :if={@queue != []}>
            <div class="group-label">Pipeline · dissolve queue</div>
            <div :for={e <- @queue} class="item" title={e["title"] || e["id"]}>
              <div class="title">{e["title"] || e["id"]}</div>
              <div class="meta">
                <span>waiting for sweep</span>
                <span :if={e["queued_at"]}>{rel_time(e["queued_at"])}</span>
              </div>
            </div>
          </div>
          <div :if={@ledger != []}>
            <div class="group-label">Pipeline · recent sweep</div>
            <div :for={e <- @ledger} class="item" title={e["title"] || e["id"]}>
              <div class="title">{e["title"] || e["id"]}</div>
              <div class="meta">
                <span>{e["outcome"]}</span>
                <span :if={e["memories"] not in [nil, []]}>{length(e["memories"])} memories</span>
                <span :if={e["at"]}>{rel_time(e["at"])}</span>
              </div>
            </div>
          </div>
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
                <span :if={pend > 0} class="staged-count">{pend} pending</span>
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
            <div :if={@active && @active_staged != []} class="stage">
              <div class="stage-label">
                Inbox · {length(@active_staged)} staged — the hourly sweep judges these; act only to preempt it
              </div>
              <%= for f <- @active_staged do %>
                <.memory_editor :if={editing?(@editing, f, true)} memory={@editing} />
                <.memory_card :if={!editing?(@editing, f, true)} memory={f} mode={:staged} />
              <% end %>
            </div>

            <div :if={@active && @active_committed == [] && @active_staged == []} class="empty-mem">
              {if @active.readonly,
                do: "This auto-memory bank is empty.",
                else: "This bank is empty. Dissolve a conversation to populate it."}
            </div>

            <%= if @active do %>
              <%= for f <- @active_committed do %>
                <.memory_editor :if={editing?(@editing, f, false)} memory={@editing} />
                <.memory_card
                  :if={!editing?(@editing, f, false)}
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

      <div :if={@dream} class="modal-bg" phx-click="close_dream">
        <div class="modal" phx-click-away="close_dream" onclick="event.stopPropagation()">
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

      <div :if={@picker} class="modal-bg" phx-click="close_picker">
        <div class="modal wide-modal" onclick="event.stopPropagation()">
          <h3>Dissolve a conversation into memory</h3>
          <p class="hint">
            The entire conversation is distilled — never a fragment — then judge-verified and committed to its project's bank automatically.
          </p>
          <div class="picker-list">
            <div
              :for={s <- @picker}
              class="picker-item"
              phx-click="distill"
              phx-value-project={s.project}
              phx-value-id={s.id}
              data-confirm={
                recently_active?(s) &&
                  "This session was active #{rel_time(s.updated_at)} — it may still be open, and dissolving consumes its transcript. Continue?"
              }
            >
              <span class="title">{s.title}</span>
              <span class="tag">{project_name(s.cwd)}</span>
              <span :if={recently_active?(s)} class="tag staged-count">active</span>
              <span class="tag">{rel_time(s.updated_at)}</span>
              <span class="tag">{s.message_count} msgs</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp editing?(nil, _f, _staged?), do: false
  defp editing?(e, f, true), do: e[:staged] == true and e.name == f.name
  defp editing?(e, f, false), do: e[:staged] != true and e.file == f.file

  # ── memory components ───────────────────────────────────────
  attr :memory, :map, required: true

  defp archived_card(assigns) do
    ~H"""
    <div class="memory archived">
      <div class="memory-head">
        <span class={["badge", @memory.type]}>{@memory.type}</span>
        <span class="memory-name">{@memory.name}</span>
        <span :if={@memory.archived_at} class="tag">archived {rel_time(@memory.archived_at)}</span>
        <div class="memory-tools">
          <button
            class="btn ok"
            phx-click="restore"
            phx-value-file={@memory.file}
            title="Restore into the bank"
          ><.ph name="arrow-counter-clockwise" /></button>
        </div>
      </div>
      <div class="memory-desc">{@memory.description}</div>
      <div class="memory-body">{@memory.body}</div>
    </div>
    """
  end

  attr :memory, :map, required: true
  attr :mode, :atom, required: true
  attr :selected, :boolean, default: false

  defp memory_card(assigns) do
    ~H"""
    <div class={["memory", @mode == :staged && "staged", @selected && "sel"]}>
      <div class="memory-head">
        <input
          :if={@mode == :committed}
          type="checkbox"
          phx-click="toggle"
          phx-value-file={@memory.file}
          checked={@selected}
        />
        <span class={["badge", @memory.type]}>{@memory.type}</span>
        <span class="memory-name">{@memory.name}</span>
        <span :if={@mode == :staged} class="badge staged-b">candidate</span>
        <span :if={@memory[:replaces] not in [nil, []]} class="badge merge-b">merges {length(
          @memory.replaces
        )}</span>
        <span :if={@memory[:recall]} class="tag">recall: {@memory.recall}</span>
        <div class="memory-tools">
          <button
            :if={@mode == :staged}
            class="btn ok"
            phx-click="approve"
            phx-value-name={@memory.name}
            title="Commit now (skips the judge)"
          ><.ph name="check" /></button>
          <button
            :if={@mode != :readonly}
            class="btn"
            phx-click="edit"
            phx-value-name={@memory.name}
            title="Edit"
          ><.ph name="pencil-simple" /></button>
          <button
            :if={@mode == :staged}
            class="btn warn"
            phx-click="reject"
            phx-value-name={@memory.name}
            title="Discard from the inbox"
          ><.ph name="x" /></button>
          <button
            :if={@mode == :committed}
            class="btn warn"
            phx-click="delete"
            phx-value-file={@memory.file}
            data-confirm={"Delete “#{@memory.name}”?"}
            title="Delete"
          ><.ph name="trash" /></button>
        </div>
      </div>
      <div class="memory-desc">{@memory.description}</div>
      <div class="memory-body">{@memory.body}</div>
    </div>
    """
  end

  attr :memory, :map, required: true

  defp memory_editor(assigns) do
    assigns = assign(assigns, types: Orrery.Memory.types())

    ~H"""
    <form class="editor" phx-submit="save">
      <input type="hidden" name="bank" value={@memory.bank} />
      <input type="hidden" name="orig_file" value={@memory[:file] || ""} />
      <input type="hidden" name="staged" value={to_string(@memory[:staged] == true)} />
      <input type="hidden" name="source" value={@memory[:source] || ""} />
      <input type="hidden" name="replaces" value={Jason.encode!(@memory[:replaces])} />
      <input class="f-name" name="name" value={@memory.name} placeholder="human-readable title" />
      <input name="description" value={@memory.description} placeholder="one-line recall summary" />
      <select name="type">
        <option :for={t <- @types} selected={t == @memory.type}>{t}</option>
      </select>
      <select name="recall">
        <option value="default" selected={@memory[:recall] not in ~w(pin index mute)}>default</option>
        <option :for={r <- ~w(pin index mute)} selected={r == @memory[:recall]}>{r}</option>
      </select>
      <textarea name="body" rows="9">{@memory.body}</textarea>
      <div class="f-actions">
        <button type="button" class="btn" phx-click="cancel_edit">cancel</button>
        <button type="submit" class="btn ok">save</button>
      </div>
    </form>
    """
  end
end
