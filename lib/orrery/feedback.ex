defmodule Orrery.Feedback do
  @moduledoc """
  Append-only inbox for user-submitted feedback. Each submission lands as one
  timestamped Markdown file under `~/.claude/@feedback/`, where machine agents
  pick them up to drive fixes back into this app.
  """

  @doc "Directory holding one Markdown file per feedback submission."
  def dir,
    do:
      Application.get_env(:orrery, :feedback_root) ||
        Path.join(System.user_home!(), ".claude/@feedback")

  @doc """
  Persist a feedback `message`. `meta` is arbitrary request context (remote IP,
  user agent) recorded in the file header. Returns `{:ok, path}`, or
  `{:error, :empty}` when the message is blank.
  """
  def write(message, meta \\ %{}) when is_binary(message) do
    case String.trim(message) do
      "" ->
        {:error, :empty}

      trimmed ->
        now = DateTime.utc_now()
        File.mkdir_p!(dir())
        path = Path.join(dir(), filename(now))
        File.write!(path, render(trimmed, meta, now))
        {:ok, path}
    end
  end

  # ISO8601 with a short unique suffix so same-second submissions never collide.
  defp filename(now) do
    stamp = now |> DateTime.to_iso8601() |> String.replace(":", "-")
    token = System.unique_integer([:positive, :monotonic])
    "#{stamp}-#{token}.md"
  end

  defp render(message, meta, now) do
    header =
      [
        {"received_at", DateTime.to_iso8601(now)},
        {"remote_ip", meta[:remote_ip]},
        {"user_agent", meta[:user_agent]}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    "---\n#{header}\n---\n\n#{message}\n"
  end
end
