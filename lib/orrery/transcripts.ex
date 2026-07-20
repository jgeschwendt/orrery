defmodule Orrery.Transcripts do
  @moduledoc """
  Parse Claude Code session JSONL transcripts into session/message/block maps.

  A session is a map; its `:messages` is a list of message maps, each carrying a
  list of content blocks (`text`, `thinking`, `tool_use`, `tool_result`, `image`).
  Metadata listings drop `:messages`.
  """

  @type_set ~w(user assistant)

  # Overridable so tests can run against fixture transcripts instead of the live ones.
  def projects_dir,
    do:
      Application.get_env(:orrery, :projects_dir) ||
        Path.join(System.user_home!(), ".claude/projects")

  @doc "Lightweight metadata for every session, newest first."
  def list_sessions do
    projects_dir()
    |> Path.join("*/*.jsonl")
    |> Path.wildcard()
    |> Enum.map(fn file -> parse_session(file, project_of(file)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.delete(&1, :messages))
    |> Enum.sort_by(&(&1.updated_at || ""), :desc)
  end

  @doc "Every session's cwd (first cwd seen per transcript) — far cheaper than list_sessions when only cwds are needed."
  def session_cwds do
    projects_dir()
    |> Path.join("*/*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(fn file -> if c = first_cwd(file), do: [c], else: [] end)
  end

  @doc "The first `cwd` recorded in a transcript file, or nil if none parses."
  def first_cwd(file) do
    file
    |> File.stream!()
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"cwd" => cwd}} when is_binary(cwd) -> cwd
        _ -> nil
      end
    end)
  end

  def get_session(project, id) do
    if Orrery.Store.component?(project) and Orrery.Store.component?(id),
      do: parse_session(Path.join([projects_dir(), project, id <> ".jsonl"]), project),
      else: nil
  end

  @doc """
  Compact-delete a session's transcript: gzip-archive it under the
  `@log/archive/YYYY-MM-DD/` (recoverable, fuel for the voyage log — same contract as
  `/delete`), then remove the live file and notify subscribers. The live file is only
  removed once the archive is safely written; returns `:ok` or `{:error, reason}`.
  """
  def delete_session(project, id) do
    if Orrery.Store.component?(project) and Orrery.Store.component?(id) do
      path = Path.join([projects_dir(), project, id <> ".jsonl"])

      result =
        with {:ok, data} <- File.read(path),
             :ok <- archive_transcript(id, data),
             do: File.rm(path)

      # The sweep runs from `mix memory.sweep` with no supervision tree — only
      # broadcast when the app (and its PubSub) is actually up.
      if Process.whereis(Orrery.PubSub),
        do:
          Phoenix.PubSub.broadcast(Orrery.PubSub, "transcripts", {:session_changed, project, id})

      result
    else
      {:error, :invalid_path}
    end
  end

  defp archive_transcript(id, data) do
    dir = Path.join(Orrery.UserLog.archive_root(), Date.to_iso8601(Date.utc_today()))

    with :ok <- File.mkdir_p(dir),
         do: File.write(Path.join(dir, id <> ".jsonl.gz"), :zlib.gzip(data))
  end

  defp project_of(file), do: file |> Path.relative_to(projects_dir()) |> Path.split() |> hd()

  @doc """
  Parse a session from its newest gzip archive in the @log archive — how the dissolve-queue
  consumer reads transcripts that `/delete` already archived. Returns nil when no
  archive exists yet (the session may still be finalizing) or it doesn't parse.
  """
  def parse_archived(id) do
    with true <- Orrery.Store.component?(id),
         # date-dir names sort chronologically, so the last wildcard hit is the
         # newest copy (finalize re-archives the final flush, possibly next day)
         path when is_binary(path) <-
           Orrery.UserLog.archive_root()
           |> Path.join("*/#{id}.jsonl.gz")
           |> Path.wildcard()
           |> List.last(),
         {:ok, gz} <- File.read(path) do
      do_parse(:zlib.gunzip(gz), Path.basename(path, ".gz"), nil)
    else
      _ -> nil
    end
  end

  def parse_session(file, project) do
    case File.read(file) do
      {:ok, text} -> do_parse(text, file, project)
      _ -> nil
    end
  end

  defp do_parse(text, file, project) do
    init = %{
      branch: nil,
      created_at: nil,
      cwd: project && decode_project(project),
      messages: [],
      model: nil,
      title: "",
      tokens: empty_tokens(),
      updated_at: nil
    }

    acc =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(init, &reduce_line/2)

    case Enum.reverse(acc.messages) do
      [] ->
        nil

      raw ->
        messages = collapse_resubmits(raw)
        title = if acc.title != "", do: acc.title, else: derive_title(messages, file)

        %{
          branch: acc.branch,
          created_at: acc.created_at,
          cwd: acc.cwd,
          file: file,
          id: Path.basename(file, ".jsonl"),
          message_count: Enum.count(messages, &(not &1.is_meta)),
          messages: messages,
          model: acc.model,
          project: project,
          title: title,
          tokens: acc.tokens,
          updated_at: acc.updated_at
        }
    end
  end

  # Claude Code appends a fresh `type:user` line each time the user edits/resubmits a
  # prompt before the assistant replies (all with parentUuid nil), so one turn can appear
  # several times. Collapse a run of consecutive user text-only messages to its last entry
  # when each is a prefix of the next (a genuine resubmission) — distinct messages are kept.
  defp collapse_resubmits(messages) do
    messages
    |> Enum.reduce([], fn m, acc ->
      case acc do
        [prev | rest] -> if resubmit?(prev, m), do: [m | rest], else: [m | acc]
        [] -> [m]
      end
    end)
    |> Enum.reverse()
  end

  defp resubmit?(prev, m) do
    case {prev, m} do
      {%{role: "user", blocks: [%{kind: "text", text: a}]},
       %{role: "user", blocks: [%{kind: "text", text: b}]}} ->
        String.starts_with?(b, a) or String.starts_with?(a, b)

      _ ->
        false
    end
  end

  defp reduce_line(line, acc) do
    case Jason.decode(line) do
      {:ok, o} -> handle(o, acc)
      _ -> acc
    end
  end

  defp handle(%{"type" => "ai-title"} = o, acc), do: %{acc | title: o["aiTitle"] || acc.title}

  defp handle(%{"type" => "custom-title"} = o, acc),
    do: %{acc | title: o["customTitle"] || o["title"] || acc.title}

  defp handle(%{"type" => type, "message" => msg} = o, acc)
       when type in @type_set and is_map(msg) do
    # cwd/branch/timestamps/tokens update regardless of whether the message has renderable blocks
    acc =
      acc
      |> put_if(:cwd, o["cwd"])
      |> put_if(:branch, o["gitBranch"])
      |> put_if(:model, msg["model"])
      |> bump_timestamps(o["timestamp"])
      |> add_tokens(msg["usage"])

    case to_blocks(msg["content"]) do
      [] ->
        acc

      blocks ->
        message = %{
          blocks: blocks,
          is_meta: meta_text?(blocks),
          is_sidechain: !!o["isSidechain"],
          model: msg["model"],
          parent_uuid: o["parentUuid"],
          role: type,
          timestamp: o["timestamp"] || "",
          tokens: usage_tokens(msg["usage"]),
          uuid: o["uuid"] || ""
        }

        %{acc | messages: [message | acc.messages]}
    end
  end

  defp handle(_, acc), do: acc

  defp put_if(acc, _key, nil), do: acc
  defp put_if(acc, _key, ""), do: acc
  defp put_if(acc, key, value), do: Map.put(acc, key, value)

  defp bump_timestamps(acc, nil), do: acc

  defp bump_timestamps(acc, ts),
    do: %{acc | created_at: acc.created_at || ts, updated_at: ts}

  # ── tokens ────────────────────────────────────────────────
  defp empty_tokens, do: %{cache_create: 0, cache_read: 0, input: 0, output: 0}

  defp usage_tokens(nil), do: nil

  defp usage_tokens(u),
    do: %{
      cache_create: u["cache_creation_input_tokens"] || 0,
      cache_read: u["cache_read_input_tokens"] || 0,
      input: u["input_tokens"] || 0,
      output: u["output_tokens"] || 0
    }

  defp add_tokens(acc, nil), do: acc

  defp add_tokens(acc, u) do
    t = acc.tokens

    %{
      acc
      | tokens: %{
          cache_create: t.cache_create + (u["cache_creation_input_tokens"] || 0),
          cache_read: t.cache_read + (u["cache_read_input_tokens"] || 0),
          input: t.input + (u["input_tokens"] || 0),
          output: t.output + (u["output_tokens"] || 0)
        }
    }
  end

  # ── blocks ────────────────────────────────────────────────
  defp to_blocks(content) when is_binary(content) do
    if content == "", do: [], else: [%{kind: "text", text: content}]
  end

  defp to_blocks(content) when is_list(content), do: Enum.flat_map(content, &block/1)
  defp to_blocks(_), do: []

  defp block(%{"type" => "text", "text" => t}) when is_binary(t) do
    if String.trim(t) == "", do: [], else: [%{kind: "text", text: t}]
  end

  defp block(%{"type" => "thinking", "thinking" => t}) when is_binary(t) do
    if String.trim(t) == "", do: [], else: [%{kind: "thinking", text: t}]
  end

  defp block(%{"type" => "tool_use"} = b),
    do: [%{kind: "tool_use", id: b["id"] || "", name: b["name"] || "?", input: b["input"]}]

  defp block(%{"type" => "tool_result"} = b),
    do: [
      %{
        kind: "tool_result",
        tool_use_id: b["tool_use_id"] || "",
        is_error: !!b["is_error"],
        content: as_text(b["content"])
      }
    ]

  defp block(%{"type" => "image"} = b),
    do: [%{kind: "image", mime: get_in(b, ["source", "media_type"]) || "image/*"}]

  defp block(_), do: []

  defp as_text(c) when is_binary(c), do: c

  defp as_text(c) when is_list(c) do
    Enum.map_join(c, "\n", fn
      s when is_binary(s) -> s
      %{"type" => "text", "text" => t} -> t
      other -> Jason.encode!(other)
    end)
  end

  defp as_text(nil), do: ""
  defp as_text(c), do: Jason.encode!(c)

  defp meta_text?([%{kind: "text", text: t}]),
    do:
      String.starts_with?(
        String.trim_leading(t),
        ["<command-", "<local-command-", "<user-prompt-submit"]
      )

  defp meta_text?(_), do: false

  # ── derived ───────────────────────────────────────────────
  defp derive_title(messages, file) do
    with %{blocks: blocks} <- Enum.find(messages, &(&1.role == "user" and not &1.is_meta)),
         %{text: t} <- Enum.find(blocks, &(&1.kind == "text")) do
      t |> String.slice(0, 80) |> String.replace(~r/\s+/, " ") |> String.trim()
    else
      _ -> Path.basename(file, ".jsonl")
    end
  end

  @doc "Decode an on-disk project dir name back into its original cwd path (lossy)."
  def decode_project(dir),
    do:
      "/" <>
        (dir
         |> String.replace_prefix("-", "")
         # `--` encodes a `/.` (hidden dir) — decode it before collapsing single dashes,
         # matching Memory.label_from_id, so `-Users-jlg--claude` → `/Users/jlg/.claude`.
         |> String.replace("--", "/.")
         |> String.replace("-", "/"))
end
