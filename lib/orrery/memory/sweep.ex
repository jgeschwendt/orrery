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
      session gains new messages; `error` retries next sweep. Custody of the ledger
      (`Runner.record/1`, `Runner.ledger/0`) and the append-only dissolve queue now
      lives in `Orrery.Memory.Pipeline.Runner`; the sweep is one caller among two (the
      other is the in-app `Pipeline` worker).
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
  alias Orrery.Memory.Pipeline.Runner

  @idle_hours 48
  @max_default 3
  @min_messages 4

  defdelegate ledger_path, to: Runner
  defdelegate queue_path, to: Runner

  @doc "Append one entry to the append-only sweep ledger (stamps `:at`). Public so the inbox drain can record its own audit lines. Delegates to `Runner.record/1`, the ledger's single writer."
  defdelegate record(entry), to: Runner

  defp archive_on_exit_dir, do: Path.join(System.user_home!(), ".claude/@log/.archive-on-exit")

  @doc """
  One sweep: drain the inbox, consume the dissolve queue, dissolve up to `max` due
  idle sessions (queue entries count against `max`), run due dreams. Returns
  a report map (also printed by the mix task), or `:locked` when another sweep is
  already running — the launchd run and the dashboard's "Sweep now" may overlap, and
  two concurrent extractions could double-process a queue entry.
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
    ledger = Runner.ledger()

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
  @doc "Pending dissolve-queue entries, oldest first (for the dashboard). Derived from the append-only queue minus permanently-ledgered ids — see `Runner.pending/1`."
  def queued, do: Runner.pending(DateTime.utc_now())

  # Serve up to `max` derived-pending entries. The queue is append-only: a consumed
  # entry drops out of `pending` because its permanent outcome lands in the ledger —
  # nothing here rewrites the queue file. `error`/`waiting` stay pending (error
  # ledgers non-permanently and retries; waiting never ledgers at all).
  defp consume_queue(max, now) do
    take = Runner.pending(now) |> Enum.take(max)
    results = Enum.map(take, &Runner.process_entry(&1, now))
    {results, length(take)}
  end

  defp sweepable?(session, ledger, now) do
    quiescent?(session, now) and not marked_archive_on_exit?(session.id) and
      case ledger[session.id] do
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

  defp dissolve(session) do
    result = Memory.distill_session(session.project, session.id)
    outcome = Runner.outcome_of(result)

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

  # ── ledger (read for the dashboard) ───────────────────────
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
