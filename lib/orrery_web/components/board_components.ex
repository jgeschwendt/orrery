defmodule OrreryWeb.BoardComponents do
  @moduledoc "Kanban-lane function components for the board (LIVE · QUEUED · PROCESSING · STAGED · COMMITTED)."
  use OrreryWeb, :html
  import OrreryWeb.UI

  # ── a lane ────────────────────────────────────────────────
  attr :label, :string, required: true
  attr :count, :integer, default: nil
  attr :body_id, :string, default: nil
  attr :stream, :boolean, default: false
  attr :empty, :string, default: nil
  slot :inner_block, required: true

  def board_column(assigns) do
    ~H"""
    <div class="col">
      <div class="col-head">
        {@label}
        <span :if={@count != nil} class="col-count">{@count}</span>
      </div>
      <div class="col-body" id={@body_id} phx-update={(@stream && "stream") || nil}>
        <div :if={@empty && @stream} id={"#{@body_id}-empty"} class="col-empty hidden only:block">
          {@empty}
        </div>
        <div :if={@empty && !@stream && @count == 0} class="col-empty">{@empty}</div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ── conversation card (LIVE · QUEUED · PROCESSING) ────────
  # A `reason` (a queue entry's `last_error`) flips a queued card into its error chrome:
  # `.card.err`, an err-chip + reason line, and a retry button (re-kicks the worker).
  attr :id, :string, default: nil
  attr :variant, :atom, required: true
  attr :title, :string, required: true
  attr :project, :string, default: nil
  attr :sid, :string, default: nil
  attr :cwd, :string, default: nil
  attr :at, :string, default: nil
  attr :msgs, :integer, default: nil
  attr :tokens, :integer, default: nil
  attr :position, :integer, default: nil
  attr :stage, :any, default: nil
  attr :reason, :any, default: nil

  def convo_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={["card convo", @variant == :processing && "processing", @reason && "err"]}
      phx-click="open_card"
      phx-value-project={@project}
      phx-value-id={@sid}
    >
      <div class="card-title">{@title}</div>

      <div :if={@variant == :live} class="card-meta">
        <span :if={@cwd}>{project_name(@cwd)}</span>
        <span>{rel_time(@at)}</span>
        <span :if={@msgs}>{@msgs} msgs</span>
        <span :if={@tokens}>{fmt_tokens(@tokens)} tok</span>
      </div>

      <div :if={@variant == :queued and !@reason} class="card-meta">
        <span class="col-count">{@position + 1}</span>
        <span>queued {rel_time(@at)}</span>
      </div>

      <.stagebar :if={@variant == :processing} stage={@stage} />

      <div :if={@reason} class="card-meta">
        <span class="err-chip">error</span>
        <span>{@reason}</span>
      </div>

      <div :if={@variant == :live} class="card-actions" onclick="event.stopPropagation()">
        <button
          class="btn"
          phx-click="dissolve"
          phx-value-project={@project}
          phx-value-id={@sid}
          phx-value-title={@title}
        ><.ph name="drop" /> dissolve</button>
        <button
          class="btn warn"
          phx-click="delete"
          phx-value-project={@project}
          phx-value-id={@sid}
          aria-label={"Delete #{@title}"}
          data-confirm={"Delete “#{@title}”? The transcript is archived, then removed — no longer resumable."}
        ><.ph name="trash" /></button>
      </div>

      <div :if={@reason} class="card-actions" onclick="event.stopPropagation()">
        <button class="btn" phx-click="retry" phx-value-id={@sid}>
          <.ph name="arrow-clockwise" /> retry
        </button>
      </div>
    </div>
    """
  end

  # ── processing telemetry ──────────────────────────────────
  attr :stage, :any, required: true

  def stagebar(assigns) do
    assigns = assign(assigns, text: stage_text(assigns.stage))

    ~H"""
    <div class="stagebar">
      <span class="spin"></span>
      <span aria-live="polite">{@text}</span>
      <span class={["step", @stage in [:extracting, :judging] && "on"]}></span>
      <span class={["step", @stage == :judging && "on"]}></span>
    </div>
    """
  end

  defp stage_text(:extracting), do: "extracting via claude…"
  defp stage_text(:judging), do: "judging via claude…"
  defp stage_text(:waiting), do: "waiting for archive…"
  defp stage_text(_), do: "processing…"

  # ── memory mini card (STAGED · COMMITTED) ─────────────────
  # The staged variant carries approve / edit / reject; `busy` disables all three while an
  # in-app mutation is in flight (cleared when the Watcher's `:memory_changed` lands).
  attr :memory, :map, required: true
  attr :staged, :boolean, default: false
  attr :busy, :boolean, default: false

  def memory_mini_card(assigns) do
    ~H"""
    <div class={["card mem", @staged && "convo"]}>
      <div class="card-title">
        <span class={["badge", @memory.type]}>{@memory.type}</span>
        {@memory.name}
      </div>
      <div :if={@memory.description not in [nil, ""]} class="card-meta">
        <span>{@memory.description}</span>
      </div>
      <div class="card-meta">
        <span :if={@memory[:source] not in [nil, ""]} class="src-tag">↳ {@memory.source}</span>
        <span :if={@memory[:bank] not in [nil, ""]} class="tag">{@memory.bank}</span>
      </div>
      <div :if={@staged} class="card-actions">
        <button
          class="btn ok"
          phx-click="approve"
          phx-value-bank={@memory.bank}
          phx-value-name={@memory.name}
          disabled={@busy}
          aria-label={"Commit #{@memory.name}"}
          title="Commit now (skips the judge)"
        ><.ph name="check" /></button>
        <button
          class="btn"
          phx-click="edit"
          phx-value-bank={@memory.bank}
          phx-value-name={@memory.name}
          disabled={@busy}
          aria-label={"Edit #{@memory.name}"}
          title="Edit"
        ><.ph name="pencil-simple" /></button>
        <button
          class="btn warn"
          phx-click="reject"
          phx-value-bank={@memory.bank}
          phx-value-name={@memory.name}
          disabled={@busy}
          aria-label={"Discard #{@memory.name}"}
          title="Discard from the inbox"
        ><.ph name="x" /></button>
      </div>
    </div>
    """
  end

  # ── outcome card (top of COMMITTED) ───────────────────────
  # Ledger-backed, so it survives a reload — a completed session's dissolve summary.
  attr :entry, :map, required: true

  def outcome_card(assigns) do
    committed = length(assigns.entry["memories"] || [])
    assigns = assign(assigns, committed: committed, dropped: assigns.entry["dropped"] || 0)

    ~H"""
    <div class="card done mem">
      <div class="card-title">{@entry["title"] || @entry["outcome"]}</div>
      <div class="card-meta">
        <span>→ {@committed} {(@committed == 1 && "memory") || "memories"}</span>
        <span :if={@dropped > 0}>· {@dropped} dropped</span>
        <span :if={@entry["bank"]}>{@entry["bank"]}</span>
        <span>{rel_time(@entry["at"])}</span>
      </div>
    </div>
    """
  end

  # ── right-anchored drawer ─────────────────────────────────
  # `phx-mounted` moves focus onto the dialog (tabindex="-1" makes it focusable) the moment
  # it opens, so keyboard/AT users land inside the drawer rather than behind the veil.
  attr :label, :string, default: "Details"
  slot :inner_block, required: true

  def drawer(assigns) do
    ~H"""
    <div class="drawer-bg" phx-click="close_drawer">
      <div
        class="drawer"
        role="dialog"
        aria-modal="true"
        aria-label={@label}
        tabindex="-1"
        phx-mounted={JS.focus()}
        phx-click-away="close_drawer"
        onclick="event.stopPropagation()"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
