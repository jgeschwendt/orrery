defmodule Orrery.Memory.Pipeline.Runner do
  @moduledoc """
  GenServer-free core of the dissolve-queue pipeline: pending-entry derivation,
  per-entry processing, and the append-only sweep ledger. Shared by the in-app
  `Orrery.Memory.Pipeline` worker and the launchd `mix memory.sweep` backstop.

  ## Append-only queue, derived pending

  `.dissolve-queue.jsonl` is a journal — producers only ever append, it is NEVER
  rewritten. "Consumed" is therefore not a queue mutation; it is a permanent outcome
  in the ledger. _Pending_ is derived, not stored:

    * read the queue lines, skipping any that don't parse (a partially-flushed
      trailing append is expected — the shell writes without a lock);
    * dedup by `id`, **first occurrence wins** (a duplicate `/dissolve` is a no-op);
    * drop every id whose newest ledger outcome is permanent
      (`#{inspect(~w(dissolved lost staged trivial))}`).

  An `error` outcome is non-permanent — the entry stays pending and carries its retry
  `attempts` (count of prior error lines) + `last_error` forward for the status API.

  ## Id-keyed ledger

  `.sweep.jsonl` is keyed by session **id alone**. Historical queue lines predate the
  `project` field, so a `{project, id}` key would miss their outcomes and reprocess
  consumed sessions. Lines without an `id` (the inbox drain's audit lines) are ignored
  by the id-keyed read — an inbox line must never be mistaken for a session outcome.
  `project` is still written when derivable, but it is display-only now.
  """

  alias Orrery.{Memory, Transcripts}

  @min_messages 4
  @permanent ~w(dissolved lost staged trivial)
  # an enqueued session whose archive never appears is unrecoverable after this long
  @queue_lost_hours 24

  def ledger_path, do: Path.join(Memory.memory_root(), ".sweep.jsonl")
  def queue_path, do: Path.join(Memory.memory_root(), ".dissolve-queue.jsonl")

  # ── pending derivation ────────────────────────────────────
  @doc """
  Pending dissolve-queue entries, oldest first — deduped by id (first wins), minus ids
  whose newest ledger outcome is permanent. An `error` entry survives with `attempts`
  (prior error count) + `last_error` attached (for the status API). `now` is accepted
  for signature symmetry with `process_entry/3`; pending itself is time-independent —
  the lost-after-24h cutoff is applied at processing time, not here.
  """
  def pending(_now \\ DateTime.utc_now()) do
    history = Enum.group_by(ledger_lines(), & &1["id"])

    queue_entries()
    |> dedup_by_id()
    |> Enum.flat_map(fn %{"id" => id} = entry ->
      entries = history[id] || []

      if (List.last(entries) || %{})["outcome"] in @permanent do
        []
      else
        errors = Enum.filter(entries, &(&1["outcome"] == "error"))

        [
          Map.merge(entry, %{
            "attempts" => length(errors),
            "last_error" => (List.last(errors) || %{})["error"]
          })
        ]
      end
    end)
  end

  defp dedup_by_id(entries) do
    entries
    |> Enum.reduce({[], MapSet.new()}, fn %{"id" => id} = e, {acc, seen} ->
      if MapSet.member?(seen, id), do: {acc, seen}, else: {[e | acc], MapSet.put(seen, id)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp queue_entries, do: json_lines(queue_path())
  defp ledger_lines, do: json_lines(ledger_path())

  # Every pipeline record — queue entry and session outcome — carries an `id`; the
  # inbox drain's audit lines deliberately don't, so keying by id skips them cleanly.
  defp json_lines(path) do
    case File.read(path) do
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

  # ── per-entry processing ──────────────────────────────────
  @doc """
  Process one pending queue entry: parse its archived transcript, distill it, and
  ledger the outcome. `progress` is a 1-arity callback receiving `:extracting` then
  `:judging` along the real distill path (no-op by default; the sweep passes a no-op,
  the in-app worker broadcasts). Keeps the sweep's original semantics:

    * no archive yet, entry < #{@queue_lost_hours}h → `waiting` (stays pending, NOT
      ledgered — one line per hour would spam it);
    * no archive, entry ≥ #{@queue_lost_hours}h → `lost` (permanent);
    * < #{@min_messages} renderable messages → `trivial` (permanent, no claude call);
    * a distill error → `error` (non-permanent, retries next pass).
  """
  def process_entry(entry, now \\ DateTime.utc_now(), progress \\ fn _ -> :ok end)

  def process_entry(%{"id" => id} = e, now, progress) do
    session = Transcripts.parse_archived(id)
    cwd = (session && session.cwd) || e["cwd"]
    project = is_binary(cwd) && Memory.sanitize(cwd)

    cond do
      is_nil(session) and queue_age_hours(e, now) >= @queue_lost_hours ->
        finish(e, %{outcome: "lost"}, project)

      is_nil(session) ->
        # the /delete finalize may not have flushed the archive yet — retry next run
        %{id: id, title: e["title"], outcome: "waiting", memories: 0}

      not is_binary(cwd) ->
        finish(e, %{outcome: "lost", error: "no cwd in transcript or queue entry"}, project)

      session.message_count < @min_messages ->
        finish(e, %{outcome: "trivial"}, project)

      true ->
        result = Memory.distill(%{session | cwd: cwd}, id, progress: progress)

        finish(
          e,
          %{
            outcome: outcome_of(result),
            bank: result.bank,
            memories: Enum.map(result.memories, & &1.name),
            dropped: result.dropped,
            staged: result.staged,
            error: result.error && inspect(result.error)
          },
          project
        )
    end
  end

  # `project` is display-only (the ledger keys by id); include it only when derivable.
  defp finish(e, extra, project) do
    base = %{source: "queue", id: e["id"], title: e["title"], queued_at: e["queued_at"]}
    base = if project, do: Map.put(base, :project, project), else: base
    entry = Map.merge(base, extra)
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

  # Consume the transcript on any successful extraction — including `staged` (the
  # candidates are safely in the inbox awaiting the next judge) and a clean zero
  # (nothing durable in the conversation). Only an extraction *error* leaves the
  # entry pending for retry. error > staged > dissolved: the permanence ladder.
  @doc "The permanence ladder for a distill result: `error` > `staged` > `dissolved`."
  def outcome_of(%{error: e}) when not is_nil(e), do: "error"
  def outcome_of(%{staged: s}) when s > 0, do: "staged"
  def outcome_of(_), do: "dissolved"

  # ── ledger ────────────────────────────────────────────────
  @doc """
  The id-keyed ledger map — newest line per session id wins (append order is read
  order). Lines without an `id` are ignored, so `sweepable?`/pending never treat an
  inbox audit line as a session outcome.
  """
  def ledger do
    Enum.reduce(ledger_lines(), %{}, fn e, acc -> Map.put(acc, e["id"], e) end)
  end

  @doc "Append one entry to the append-only sweep ledger (stamps `:at`). The single writer of the ledger; the inbox drain records its own audit lines through here too."
  def record(entry) do
    File.mkdir_p!(Memory.memory_root())

    line =
      entry
      |> Map.put(:at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> Jason.encode!()

    File.write!(ledger_path(), line <> "\n", [:append])
  end
end
