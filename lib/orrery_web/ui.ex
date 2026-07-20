defmodule OrreryWeb.UI do
  @moduledoc "Shared function components + formatting helpers for the viewer."
  use Phoenix.Component

  # ── phosphor icon ─────────────────────────────────────────
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def ph(assigns) do
    ~H"""
    <i class={["ph ph-#{@name}", @class]} aria-hidden="true"></i>
    """
  end

  # ── nav rail ──────────────────────────────────────────────
  attr :active, :atom, required: true

  def rail(assigns) do
    ~H"""
    <nav class="rail">
      <.link navigate="/" class={rail_class(@active == :board)} title="Board"><.ph name="kanban" /></.link>
      <.link navigate="/log" class={rail_class(@active == :log)} title="Voyage log"><.ph name="compass" /></.link>
      <.link navigate="/memories" class={rail_class(@active == :memories)} title="Memory banks"><.ph name="brain" /></.link>
      <.link navigate="/routines" class={rail_class(@active == :routines)} title="Routines"><.ph name="lightning" /></.link>
    </nav>
    """
  end

  defp rail_class(true), do: "on"
  defp rail_class(_), do: nil

  # ── transcript ────────────────────────────────────────────
  attr :msg, :map, required: true

  def message(assigns) do
    # Claude Code files tool results as role:user messages — don't slap a "USER" banner on
    # a turn that's purely a tool result; let the result block stand under its tool_use.
    assigns =
      assign(
        assigns,
        :tool_result_only,
        assigns.msg.blocks != [] and Enum.all?(assigns.msg.blocks, &(&1.kind == "tool_result"))
      )

    ~H"""
    <div class={["msg", @msg.is_sidechain && "side", @tool_result_only && "tool-only"]}>
      <div :if={!@tool_result_only} class={["role", @msg.role]}>
        <span>{@msg.role}</span>
        <span :if={@msg.is_sidechain} class="tag">↳ subagent</span>
        <span :if={@msg.model} class="time">{@msg.model}</span>
        <span class="time">{rel_time(@msg.timestamp)}</span>
      </div>
      <.block :for={b <- @msg.blocks} block={b} />
    </div>
    """
  end

  attr :block, :map, required: true

  def block(%{block: %{kind: "text"}} = assigns),
    do: ~H|<div class="block text">{@block.text}</div>|

  def block(%{block: %{kind: "thinking"}} = assigns),
    do: ~H|<div class="block thinking">{@block.text}</div>|

  def block(%{block: %{kind: "image"}} = assigns),
    do: ~H|<div class="block tag">⎙ image ({@block.mime})</div>|

  def block(%{block: %{kind: "tool_use"}} = assigns) do
    ~H"""
    <details class="block tool">
      <summary>
        <.ph name="caret-right" class="chev" />
        <span class="name">{@block.name}</span>
        <span class="summary">{one_line(@block.input)}</span>
      </summary>
      <pre>{Jason.encode!(@block.input, pretty: true)}</pre>
    </details>
    """
  end

  def block(%{block: %{kind: "tool_result"}} = assigns) do
    ~H"""
    <details class={["block result", @block.is_error && "err"]}>
      <summary>
        <.ph name="caret-right" class="chev" />
        <span class="name">{if @block.is_error, do: "error", else: "result"}</span>
        <span class="summary">{collapse(@block.content, 90)}</span>
      </summary>
      <pre>{@block.content}</pre>
    </details>
    """
  end

  def block(assigns), do: ~H||

  # ── helpers ───────────────────────────────────────────────
  def project_name(cwd),
    do: cwd |> String.split("/") |> Enum.reject(&(&1 == "")) |> List.last() || cwd

  def fmt_tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  def fmt_tokens(n), do: to_string(n)

  def collapse(s, len) when is_binary(s),
    do: s |> String.replace(~r/\s+/, " ") |> String.slice(0, len)

  def collapse(_, _), do: ""

  def one_line(input) when is_map(input) do
    v =
      input["command"] || input["file_path"] || input["path"] || input["pattern"] ||
        input["query"] || input["description"]

    if is_binary(v), do: collapse(v, 90), else: input |> Jason.encode!() |> collapse(90)
  end

  def one_line(_), do: ""

  def rel_time(iso) when iso in [nil, ""], do: ""

  def rel_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        case DateTime.diff(DateTime.utc_now(), dt) do
          s when s < 60 -> "just now"
          s when s < 3600 -> "#{div(s, 60)}m ago"
          s when s < 86_400 -> "#{div(s, 3600)}h ago"
          s -> "#{div(s, 86_400)}d ago"
        end

      _ ->
        ""
    end
  end
end
