defmodule Orrery.Memory.Dream do
  @moduledoc """
  The dream: the sleep-time pass — between sessions, spend compute making each bank
  *smaller and sharper* rather than waiting for recall to fail. (Offline consolidation
  is the best-evidenced quality axis for a personal memory bank — see
  the claude-memory-system gigaresearch report.) (The memory pass formerly
  labeled consolidation; distinct from the voyage log (Orrery.UserLog).)

  A bank is due when it has gained `@growth_trigger`+ memories since its last pass and
  the last pass is `@min_interval_hours`+ old (state in the bank's
  `_dream.json`). One `claude` call reads the whole bank (they're small by
  design) and proposes a capped set of ops; each op is applied through
  `Orrery.Memory.commit_memory`/`delete_memory`, so consolidation inherits every
  safety property of a normal commit — archive-over-delete, collision suffixes,
  `created` lineage across merges, index regeneration. The op set is deliberately
  tiny (merge · rewrite · archive) and the instruction is net-non-increasing: a
  consolidation may never grow the bank.
  """

  alias Orrery.Memory

  @growth_trigger 5
  @min_interval_hours 20
  @max_ops 6

  @ops_schema %{
    "type" => "object",
    "properties" => %{
      "ops" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "op" => %{"enum" => ["archive", "merge", "rewrite"]},
            "files" => %{"type" => "array", "items" => %{"type" => "string"}},
            "reason" => %{"type" => "string"},
            "memory" => %{
              "type" => "object",
              "properties" => %{
                "body" => %{"type" => "string"},
                "description" => %{"type" => "string"},
                "name" => %{"type" => "string"},
                "type" => %{"enum" => ~w(feedback project reference user)}
              },
              "required" => ~w(body description name type)
            }
          },
          "required" => ~w(op files reason)
        }
      }
    },
    "required" => ["ops"]
  }

  @doc "Run the dream on every due managed bank. Returns a list of per-bank reports."
  def run_due do
    case File.ls(Memory.memory_root()) do
      {:ok, dirs} ->
        dirs
        |> Enum.reject(&(String.starts_with?(&1, ".") or String.starts_with?(&1, "_")))
        |> Enum.filter(&File.dir?(Path.join(Memory.memory_root(), &1)))
        |> Enum.filter(&(baseline!(&1) and due?(&1)))
        |> Enum.map(&run/1)

      _ ->
        []
    end
  end

  # A bank seen for the first time gets a baseline instead of a pass: growth is
  # measured from here on, so switching the sweep on never mass-consolidates a
  # hand-curated backlog in one unsupervised run.
  defp baseline!(bank) do
    if read_state(bank) == %{} do
      write_state(bank, [])
      false
    else
      true
    end
  end

  defp state_path(bank), do: Path.join([Memory.memory_root(), bank, "_dream.json"])

  defp legacy_state_path(bank),
    do: Path.join([Memory.memory_root(), bank, "_consolidation.json"])

  # Migration: read the new `_dream.json`; when only a pre-rename `_consolidation.json`
  # is present, adopt it verbatim (its count preserves the growth delta) and move it to
  # `_dream.json`, so no bank loses its baseline across the rename (a lost baseline
  # re-triggers baseline-on-first-sight — safe but counter-less). Idempotent: once
  # `_dream.json` exists this is a plain read.
  defp read_state(bank) do
    case decode_state(state_path(bank)) do
      :error ->
        case decode_state(legacy_state_path(bank)) do
          :error ->
            %{}

          map ->
            Orrery.Store.write!(state_path(bank), Jason.encode!(map, pretty: true))
            File.rm(legacy_state_path(bank))
            map
        end

      map ->
        map
    end
  end

  defp decode_state(path) do
    with {:ok, txt} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(txt) do
      map
    else
      _ -> :error
    end
  end

  defp due?(bank) do
    memories = Memory.bank_memories(bank)
    state = read_state(bank)

    grown = length(memories) - (state["count"] || 0) >= @growth_trigger

    rested =
      case DateTime.from_iso8601(state["at"] || "") do
        {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt, :hour) >= @min_interval_hours
        _ -> true
      end

    memories != [] and grown and rested
  end

  @doc "Run the dream on one bank now (also used by the dashboard's manual trigger)."
  def run(bank) do
    memories = Memory.bank_memories(bank)

    prompt = """
    You are the DREAM pass over one bank of a personal memory store — an
    autonomous rewrite with no human review; every op you return is applied to disk
    directly. Your job is a smaller, sharper bank; zero ops is a common, correct outcome.

    THE DREAM — the user's standing curation guidance; it defines what deserves to
    remain a memory:
    #{Memory.get_dream()}

    BANK "#{bank}" (#{length(memories)} memories, full bodies):
    #{Enum.map_join(memories, "\n===\n", &"FILE #{&1.file}\nname: #{&1.name}\ndescription: #{&1.description}\ntype: #{&1.type}\ncreated: #{&1.created}\n#{&1.body}")}

    ## Phase 1 — Orient
    Read the whole bank above before judging any single memory. Look for its shape:
    clusters restating one idea, names or descriptions too vague to trigger recall,
    facts that events have outrun.

    ## Phase 2 — Weigh each memory against the bars
    durable (useful in a future, unrelated session) · non-derivable (not recoverable
    from the project's code/git/artifacts) · one idea per memory · description
    specific enough to trigger recall — all read under the dream. The created/updated
    stamps are the timeline: when two memories disagree, the newer fact wins.

    ## Phase 3 — Propose at most #{@max_ops} ops
    - merge — 2+ memories carrying ONE idea between them → "files" + one consolidated
      "memory". Keep the most specific detail from every source; preserve every
      [[wikilink]]; a merge that loses a fact is worse than no merge.
    - rewrite — 1 memory whose name or description would fail to trigger recall →
      "files" = [that file] + the sharpened "memory". Clarify only; never add facts
      the source doesn't carry.
    - archive — 1 memory that is stale, superseded, or ephemeral-in-hindsight →
      "files" = [that file], no "memory".

    Hard rules — an op violating any of these is discarded unapplied:
    - Every "files" entry is a filename from the bank above, verbatim.
    - A consolidation never grows the bank.
    - Never invent: every sentence you output must be derivable from the inputs.

    When in doubt, do nothing. A skipped merge costs one redundant recall; a wrong op
    silently corrupts the user's memory.
    """

    case Orrery.Claude.run(prompt, schema: @ops_schema) do
      {:ok, %{output: %{"ops" => ops}, cost: cost}} ->
        applied =
          ops
          |> Enum.take(@max_ops)
          |> Enum.filter(&valid_op?(&1, memories))
          |> Enum.map(&apply_op(&1, bank))

        write_state(bank, applied)
        %{bank: bank, ops: applied, cost: cost, error: nil}

      {:error, reason} ->
        %{bank: bank, ops: [], cost: 0, error: reason}
    end
  end

  # An op may only touch files that really are committed memories of this bank, and
  # merge/rewrite must carry a replacement memory.
  defp valid_op?(op, memories) do
    files = op["files"] || []
    known = MapSet.new(memories, & &1.file)

    files != [] and Enum.all?(files, &MapSet.member?(known, &1)) and
      case op["op"] do
        "archive" -> true
        "merge" -> length(files) >= 2 and is_map(op["memory"])
        "rewrite" -> length(files) == 1 and is_map(op["memory"])
        _ -> false
      end
  end

  defp apply_op(%{"op" => "archive"} = op, bank) do
    for f <- op["files"], do: Memory.delete_memory(bank, f)
    summarize(op)
  end

  defp apply_op(%{"op" => _, "memory" => m} = op, bank) do
    Memory.commit_memory(%{
      bank: bank,
      body: m["body"],
      description: m["description"],
      name: m["name"],
      replaces: op["files"],
      source: nil,
      type: m["type"]
    })

    summarize(op)
  end

  defp summarize(op),
    do: %{op: op["op"], files: op["files"], reason: op["reason"], name: op["memory"]["name"]}

  defp write_state(bank, applied) do
    state = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "count" => length(Memory.bank_memories(bank)),
      "last_ops" => length(applied)
    }

    Orrery.Store.write!(state_path(bank), Jason.encode!(state, pretty: true))
    File.rm(legacy_state_path(bank))
  end
end
