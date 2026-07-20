defmodule Orrery.Memory.Sweep do
  @moduledoc """
  The automatic half of the memory lifecycle: find conversations that ended without a
  manual `/dissolve`, dissolve them through the same extract → judge → commit pipeline,
  and consume their transcripts (gzip-archive to @log, then remove — recoverable,
  not resumable). Driven unattended by the "Memory sweep" routine (launchd), so every
  decision here must be idempotent and fail-safe:

    * **Quiescence, not hooks** — a session qualifies only after `@idle_hours` without
      a new message. Session-end hooks were deliberately rejected (they're disabled in
      some sessions, and an end event can't shorten the idle wait anyway — a
      just-ended session may still be resumed tomorrow).
    * **Ledger** (`@memory/.sweep.jsonl`, append-only) — one line per handled session;
      makes re-runs no-ops and gives the dashboard provenance. A `dissolved`/`staged`
      outcome is permanent (the transcript is consumed); `trivial` re-arms when the
      session gains new messages; `error` retries next sweep.
    * **Trivial guard** — sessions with fewer than `@min_messages` renderable messages
      are ledgered without spending a claude call; their transcripts are left alone.
    * **Caps** — at most `max` (default 3) dissolves per run, so a backlog or a
      runaway scheduler can't burn unbounded tokens.
    * **Respect the wrapper** — a live transcript pre-marked archive-on-exit
      (`@log/.archive-on-exit/<sid>`) belongs to the session-end machinery; skipped.

  Mid-session inbox entries (`.staging.json`), the **dissolve queue**
  (`.dissolve-queue.jsonl` — sessions a `/dissolve` explicitly enqueued; their
  transcripts are already gzip-archived by `/delete`, so consumption reads from the
  @log archive) and due dream passes ride the same sweep, so one scheduled
  entry point drives the whole autonomous lifecycle. Queue entries are explicit user
  intent — they skip the quiescence wait and are served before idle sessions, but
  share the per-run dissolve cap.
  """

  alias Orrery.{Memory, Transcripts}

  @idle_hours 48
  @max_default 3
  @min_messages 4
  # an enqueued session whose archive never appears is unrecoverable after this long
  @queue_lost_hours 24

  def ledger_path, do: Path.join(Memory.memory_root(), ".sweep.jsonl")
  def queue_path, do: Path.join(Memory.memory_root(), ".dissolve-queue.jsonl")

  defp archive_on_exit_dir, do: Path.join(System.user_home!(), ".claude/@log/.archive-on-exit")

  @doc """
  One sweep: drain the inbox, consume the dissolve queue, dissolve up to `max` due
  idle sessions (queue entries count against `max`), run due dreams. Returns
  a report map (also printed by the mix task), or `:locked` when another sweep is
  already running — the launchd run and the dashboard's "Sweep now" may overlap, and
  two concurrent queue rewrites could resurrect a consumed entry.
  """
  def run(opts \\ []) do
    case Memory.Locks.with_lock(:pipeline, fn -> do_run(opts) end) do
      {:ok, report} -> report
      {:error, :locked} -> :locked
    end
  end

  @doc "The shared one-line sweep summary body; call sites add their own prefix and terminator."
  def summary_line(report) do
    inbox = report.inbox

    "#{length(report.queue)} queued · #{report.considered} considered · " <>
      "#{length(report.results)} dissolved-or-tried · " <>
      "#{report.trivial} trivial · #{report.deferred} deferred · " <>
      "inbox #{inbox.committed}✓/#{inbox.dropped}✗/#{inbox.kept}… · " <>
      "#{length(report.dreamt)} bank(s) dreamt"
  end

  defp do_run(opts) do
    max = opts[:max] || @max_default
    now = DateTime.utc_now()
    ledger = read_ledger()

    {queue_results, queue_used} = consume_queue(max, now)

    {due, trivial} =
      Transcripts.list_sessions()
      |> Enum.filter(&sweepable?(&1, ledger, now))
      |> Enum.split_with(&(&1.message_count >= @min_messages))

    Enum.each(
      trivial,
      &record(%{outcome: "trivial", project: &1.project, id: &1.id, updated_at: &1.updated_at})
    )

    idle_max = max(max - queue_used, 0)
    results = due |> Enum.take(idle_max) |> Enum.map(&dissolve/1)

    %{
      considered: length(due) + length(trivial),
      dreamt: Orrery.Memory.Dream.run_due(),
      deferred: max(length(due) - idle_max, 0),
      inbox: Memory.drain_inbox(),
      queue: queue_results,
      results: results,
      trivial: length(trivial)
    }
  end

  # ── dissolve queue ────────────────────────────────────────
  @doc "Pending dissolve-queue entries, oldest first (for the dashboard)."
  def queued do
    case File.read(queue_path()) do
      {:ok, txt} ->
        txt
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"id" => id} = e} when is_binary(id) -> [e]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # Serve up to `max` entries; an entry survives the rewrite only while retrying
  # (extraction error, or archive not yet flushed). Everything else — dissolved,
  # staged, trivial, lost — is consumed.
  defp consume_queue(max, now) do
    entries = queued()
    {take, defer} = Enum.split(entries, max)
    results = Enum.map(take, &consume_entry(&1, now))

    keep = for {e, r} <- Enum.zip(take, results), r.outcome in ["error", "waiting"], do: e

    if entries != [], do: write_queue(keep ++ defer)
    {results, length(take)}
  end

  defp consume_entry(%{"id" => id} = e, now) do
    session = Transcripts.parse_archived(id)
    cwd = (session && session.cwd) || e["cwd"]

    cond do
      is_nil(session) and queue_age_hours(e, now) >= @queue_lost_hours ->
        finish(e, %{outcome: "lost"})

      is_nil(session) ->
        # the /delete finalize may not have flushed the archive yet — retry next run
        %{id: id, title: e["title"], outcome: "waiting", memories: 0}

      not is_binary(cwd) ->
        finish(e, %{outcome: "lost", error: "no cwd in transcript or queue entry"})

      session.message_count < @min_messages ->
        finish(e, %{outcome: "trivial"})

      true ->
        result = Memory.distill(%{session | cwd: cwd}, id)
        outcome = outcome_of(result)

        finish(e, %{
          outcome: outcome,
          bank: result.bank,
          memories: Enum.map(result.memories, & &1.name),
          dropped: result.dropped,
          staged: result.staged,
          error: result.error && inspect(result.error)
        })
    end
  end

  defp finish(e, extra) do
    entry =
      Map.merge(
        %{source: "queue", id: e["id"], title: e["title"], queued_at: e["queued_at"]},
        extra
      )

    record(entry)

    %{
      id: e["id"],
      title: e["title"],
      outcome: entry.outcome,
      memories: length(entry[:memories] || [])
    }
  end

  defp queue_age_hours(e, now) do
    case DateTime.from_iso8601(e["queued_at"] || "") do
      {:ok, dt, _} -> DateTime.diff(now, dt, :hour)
      # unstampable entries can never prove their age — treat as old enough to lose
      _ -> @queue_lost_hours
    end
  end

  defp write_queue(entries),
    do:
      Orrery.Store.write!(queue_path(), Enum.map_join(entries, "", &(Jason.encode!(&1) <> "\n")))

  defp sweepable?(session, ledger, now) do
    quiescent?(session, now) and not marked_archive_on_exit?(session.id) and
      case ledger[{session.project, session.id}] do
        nil -> true
        # a "trivial" verdict re-arms when the session has since gained messages
        %{"outcome" => "trivial"} = e -> e["updated_at"] != session.updated_at
        %{"outcome" => "error"} -> true
        _permanent -> false
      end
  end

  defp quiescent?(%{updated_at: ts}, now) when is_binary(ts) and ts != "" do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.diff(now, dt, :hour) >= @idle_hours
      _ -> false
    end
  end

  defp quiescent?(_, _), do: false

  @doc "True when a live transcript is pre-marked archive-on-exit — the session-end machinery owns it; neither the sweep nor a dashboard dissolve may consume it."
  def marked_archive_on_exit?(id), do: File.exists?(Path.join(archive_on_exit_dir(), id))

  # Consume the transcript on any successful extraction — including `staged` (the
  # candidates are safely in the inbox awaiting the next judge) and a clean zero
  # (nothing durable in the conversation). Only an extraction *error* leaves the
  # transcript for retry.
  # error > staged > dissolved: the permanence ladder for a distill result
  defp outcome_of(%{error: e}) when not is_nil(e), do: "error"
  defp outcome_of(%{staged: s}) when s > 0, do: "staged"
  defp outcome_of(_), do: "dissolved"

  defp dissolve(session) do
    result = Memory.distill_session(session.project, session.id)
    outcome = outcome_of(result)

    if outcome != "error", do: Transcripts.delete_session(session.project, session.id)

    record(%{
      outcome: outcome,
      project: session.project,
      id: session.id,
      title: session.title,
      bank: result.bank,
      memories: Enum.map(result.memories, & &1.name),
      dropped: result.dropped,
      staged: result.staged,
      error: result.error && inspect(result.error),
      updated_at: session.updated_at
    })

    %{id: session.id, title: session.title, outcome: outcome, memories: length(result.memories)}
  end

  # ── ledger ────────────────────────────────────────────────
  # Append-only JSONL; the newest line per {project, id} wins on read.
  @doc "Append one entry to the append-only sweep ledger (stamps `:at`). Public so the inbox drain can record its own audit lines."
  def record(entry) do
    File.mkdir_p!(Memory.memory_root())

    line =
      entry
      |> Map.put(:at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> Jason.encode!()

    File.write!(ledger_path(), line <> "\n", [:append])
  end

  defp read_ledger do
    case File.read(ledger_path()) do
      {:ok, txt} ->
        txt
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case Jason.decode(line) do
            {:ok, %{"project" => p, "id" => id} = e} -> Map.put(acc, {p, id}, e)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc "Newest-first ledger entries for the dashboard, capped at `n`."
  def recent(n \\ 30) do
    case File.read(ledger_path()) do
      {:ok, txt} ->
        txt
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.take(n)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, e} -> [e]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end
end
