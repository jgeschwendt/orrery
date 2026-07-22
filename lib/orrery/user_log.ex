defmodule Orrery.UserLog do
  @moduledoc """
  The log — "what I did" — a day-by-day record for looking back across the year. Plain
  files under `/Users/jlg/GitHub/jgeschwendt/orrery/data/@log`, one page per day, mirroring
  `Orrery.Memory`'s habit of keeping markdown under
  `/Users/jlg/GitHub/jgeschwendt/livebook/data` and shelling out to `claude` for the hard part.

  Each day holds up to two files so the auto and manual halves never clobber each other:

    * `YYYY-MM-DD.voyage.md`  — the **voyage log**: a compact summary of the day's
      conversations, written by `claude` (on demand here, or nightly via a Routine).
    * `YYYY-MM-DD.notes.md`  — your own notes for the day, edited in the dashboard.

  The voyage log is the log's sibling to `Memory`'s dissolve: dissolve distills one
  conversation into durable memories; the voyage log distills a whole *day* into one page.
  When a session is killed (`/delete` / `/dissolve`), its raw transcript is "compact-deleted"
  — gzip-archived under `archive/YYYY-MM-DD/` rather than removed — so the voyage log still
  has the day's conversations to draw on and nothing is lost. The lone exception is
  `/delete hard`, which erases the transcript outright (no archive) and so never feeds the
  voyage log.
  """

  alias Orrery.Transcripts

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  # ── paths ─────────────────────────────────────────────────
  # Overridable so tests can run against a tmp log instead of the live one.
  def log_root,
    do: Application.get_env(:orrery, :log_root) || "/Users/jlg/GitHub/jgeschwendt/orrery/data/@log"

  def archive_root, do: Path.join(log_root(), "archive")

  defp voyage_path(date), do: Path.join(log_root(), "#{date}.voyage.md")
  defp notes_path(date), do: Path.join(log_root(), "#{date}.notes.md")

  # A log page key is strictly `YYYY-MM-DD`; anything else is a tampered param and
  # must never reach a file path or the voyage prompt (which tells claude what to write).
  defp date?(date), do: is_binary(date) and Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, date)

  @doc "Today's date as an ISO string (`YYYY-MM-DD`), the log's page key."
  def today, do: Date.to_iso8601(Date.utc_today())

  def weekday(date) do
    case Date.from_iso8601(to_string(date)) do
      {:ok, d} -> Enum.at(@weekdays, Date.day_of_week(d) - 1)
      _ -> ""
    end
  end

  # ── listing (the year lookback) ───────────────────────────
  @doc """
  Every day worth showing, newest first: the union of days that have a voyage page, a
  notes page, archived transcripts, or live conversations. Each entry is a lightweight
  map — `:date`, `:logged?`, `:noted?`, `:archived` count, and a one-line `:preview`.
  """
  def list_days(sessions \\ Transcripts.list_sessions()) do
    archive_days = archive_dates()
    file_days = MapSet.union(page_dates(), archive_days)
    conv_days = session_dates(sessions)

    (MapSet.to_list(file_days) ++ MapSet.to_list(conv_days))
    |> Enum.uniq()
    |> Enum.sort(:desc)
    |> Enum.map(fn date ->
      voyage = read_voyage(date)

      %{
        archived: (MapSet.member?(archive_days, date) && archived_count(date)) || 0,
        date: date,
        logged?: voyage != "",
        noted?: read_notes(date) != "",
        preview: preview_of(voyage),
        weekday: weekday(date)
      }
    end)
  end

  defp page_dates do
    case File.ls(log_root()) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          case Regex.run(~r/^(\d{4}-\d{2}-\d{2})\.(voyage|notes)\.md$/, name) do
            [_, date, _] -> [date]
            _ -> []
          end
        end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp archive_dates do
    case File.ls(archive_root()) do
      {:ok, dirs} -> dirs |> Enum.filter(&date_dir?/1) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  defp session_dates(sessions) do
    sessions
    |> Enum.map(&day_of/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp date_dir?(name), do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, name)
  defp day_of(%{updated_at: ts}) when is_binary(ts) and ts != "", do: String.slice(ts, 0, 10)
  defp day_of(_), do: nil

  defp preview_of(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.find("", fn line ->
      not String.starts_with?(line, ["#", "-", "---", "date:", "type:"])
    end)
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 140)
  end

  # ── a single day ──────────────────────────────────────────
  @doc "Everything needed to render one day: its voyage, notes, and the day's conversations."
  def get_day(date, sessions \\ Transcripts.list_sessions()) do
    if date?(date) do
      %{
        archived: list_archived(date),
        conversations: conversations_on(date, sessions),
        date: date,
        notes: read_notes(date),
        voyage: read_voyage(date),
        weekday: weekday(date)
      }
    else
      %{archived: [], conversations: [], date: date, notes: "", voyage: "", weekday: ""}
    end
  end

  def read_voyage(date), do: read_or_empty(voyage_path(date))
  def read_notes(date), do: read_or_empty(notes_path(date))

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, txt} -> txt
      _ -> ""
    end
  end

  @doc "Persist the day's manual notes. Empty text removes the file."
  def write_notes(date, text) do
    if date?(date) do
      File.mkdir_p!(log_root())
      text = String.trim(to_string(text))

      if text == "",
        do: File.rm(notes_path(date)),
        else: File.write!(notes_path(date), text <> "\n")

      :ok
    else
      {:error, :invalid_date}
    end
  end

  @doc "Live (un-killed) sessions whose last activity fell on `date`, newest first."
  def conversations_on(date, sessions \\ Transcripts.list_sessions()) do
    Enum.filter(sessions, &(day_of(&1) == date))
  end

  # ── compact-delete archive ────────────────────────────────
  @doc "Gzip-archived transcripts compact-deleted on `date` (filenames only)."
  def list_archived(date) do
    dir = Path.join(archive_root(), date)

    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".jsonl.gz")) |> Enum.sort()
      _ -> []
    end
  end

  defp archived_count(date), do: length(list_archived(date))

  # ── the voyage log (shell out to claude) ─────────────────
  @doc """
  Log a day's voyage: run the voyage prompt through the local `claude` CLI, which reads
  that day's conversations and writes `YYYY-MM-DD.voyage.md` itself. Returns the CLI's
  text. Slow (a full claude turn) — drive it from a `start_async` in the LiveView.
  """
  def voyage(date \\ nil) do
    date = date || today()

    if date?(date) do
      File.mkdir_p!(log_root())

      tmp =
        Path.join(System.tmp_dir!(), "claude_voyage_#{System.unique_integer([:positive])}.txt")

      File.write!(tmp, voyage_prompt(date))
      claude = System.find_executable("claude") || "claude"

      # --no-session-persistence: the voyage log must not leave its own transcript in
      # ~/.claude/projects — else it clutters Conversations and the next voyage log
      # summarizes its own run. Print-mode only, which is exactly how we run it.
      {out, _} =
        System.cmd(
          "sh",
          ["-c", ~s('#{claude}' --permission-mode=auto --no-session-persistence -p < '#{tmp}')],
          stderr_to_stdout: true
        )

      File.rm(tmp)
      %{date: date, output: out}
    else
      %{date: date, output: ""}
    end
  end

  @doc """
  The single source-of-truth voyage prompt, parameterized by target date. Self-contained
  so it runs identically whether driven from the dashboard (`voyage/1`) or unattended by
  the "Voyage log" Routine via launchd. Pass `nil` for a routine that should target the
  current day at run time.
  """
  def voyage_prompt(date \\ nil) do
    home = System.user_home!()

    target =
      if date, do: "**#{date}** (#{weekday(date)})", else: "today (compute it with `date +%F`)"

    """
    You are the VOYAGE LOG — the log's nightly distiller. Running UNATTENDED: never
    wait for input or ask questions. Your one job is to write a compact log page for a
    single day from that day's Claude Code conversations, then stop.

    TARGET DAY: #{target}.

    GATHER the day's conversations (a conversation belongs to the target day if its last
    message timestamp, or failing that the file's modified date, falls on that day):
      - live transcripts:    #{home}/.claude/projects/*/*.jsonl
      - compact-deleted ones: /Users/jlg/GitHub/jgeschwendt/orrery/data/@log/archive/<TARGET-DATE>/*.jsonl.gz  (gunzip to read)
    Each `.jsonl` is one conversation: newline-delimited JSON, user/assistant messages
    under the `message` key. If there are NO conversations for the day, write nothing and
    stop — do not invent a page.

    WRITE exactly one file: `/Users/jlg/GitHub/jgeschwendt/orrery/data/@log/<TARGET-DATE>.voyage.md`. Overwrite it
    if it exists (it is regenerable). Touch NOTHING else — never the matching
    `<TARGET-DATE>.notes.md` (those are the human's own notes) and never any transcript.

    FORMAT the page exactly like this (keep it tight — a glance, not a transcript):

        ---
        date: <TARGET-DATE>
        type: voyage
        ---

        # <TARGET-DATE> · <Weekday>

        <2–4 sentences: what actually got done across the day, in plain past tense.>

        ## Threads
        - **<project name>** — <one line: what happened in that conversation>
        - …one bullet per meaningful conversation, skip trivial/empty ones…

        ## Worth remembering
        - <0–3 durable lessons that outlive today — the kind of thing you'd `/dissolve`
          into a memory bank. Omit this whole section if nothing qualifies.>

    Write past tense, specific, no filler. Then print one line: the path you wrote and the
    thread count. Stop.
    """
  end
end
