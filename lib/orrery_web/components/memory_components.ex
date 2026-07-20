defmodule OrreryWeb.MemoryComponents do
  @moduledoc "Shared memory card / editor function components (memory bank + board views)."
  use OrreryWeb, :html
  import OrreryWeb.UI

  attr :memory, :map, required: true

  def archived_card(assigns) do
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
            aria-label={"Restore #{@memory.name}"}
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

  def memory_card(assigns) do
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
            aria-label={"Commit #{@memory.name}"}
            title="Commit now (skips the judge)"
          ><.ph name="check" /></button>
          <button
            :if={@mode != :readonly}
            class="btn"
            phx-click="edit"
            phx-value-name={@memory.name}
            aria-label={"Edit #{@memory.name}"}
            title="Edit"
          ><.ph name="pencil-simple" /></button>
          <button
            :if={@mode == :staged}
            class="btn warn"
            phx-click="reject"
            phx-value-name={@memory.name}
            aria-label={"Discard #{@memory.name}"}
            title="Discard from the inbox"
          ><.ph name="x" /></button>
          <button
            :if={@mode == :committed}
            class="btn warn"
            phx-click="delete"
            phx-value-file={@memory.file}
            aria-label={"Delete #{@memory.name}"}
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

  def memory_editor(assigns) do
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

  # ── editor form-param coercion (shared by the board + bank save handlers) ──
  def replaces_for(%{"staged" => "true", "replaces" => r}) when is_binary(r), do: Jason.decode!(r)
  def replaces_for(%{"orig_file" => f}) when f not in [nil, ""], do: [f]
  def replaces_for(_), do: nil

  def blank_to_nil(""), do: nil
  def blank_to_nil(v), do: v

  def recall_for(r) when r in ~w(pin index mute), do: r
  def recall_for(_), do: nil
end
