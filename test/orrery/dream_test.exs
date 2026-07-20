defmodule Orrery.Memory.DreamTest do
  use ExUnit.Case, async: false

  alias Orrery.Memory
  alias Orrery.Memory.Dream

  # These fixtures never reach a `claude` call: the baseline-on-first-sight guard
  # short-circuits the first run, and growth-since-baseline stays under the trigger
  # on the second — so the whole suite exercises Dream's claude-free paths.

  @bank "-tmp-project"

  setup do
    root = Path.join(System.tmp_dir!(), "dream_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:orrery, :memory_root, root)

    on_exit(fn ->
      Application.delete_env(:orrery, :memory_root)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp commit(attrs) do
    Memory.commit_memory(
      Map.merge(
        %{
          bank: @bank,
          body: "body",
          description: "desc",
          name: "A fact",
          replaces: nil,
          source: nil,
          type: "reference"
        },
        attrs
      )
    )
  end

  defp seed_bank do
    :ok = commit(%{name: "First fact", body: "one"})
    :ok = commit(%{name: "Second fact", body: "two"})
    :ok = commit(%{name: "Third fact", body: "three"})
  end

  test "first run_due baselines the bank and never dreams", %{root: root} do
    seed_bank()
    count = length(Memory.bank_memories(@bank))

    assert Dream.run_due() == []

    state_path = Path.join([root, @bank, "_dream.json"])
    assert File.exists?(state_path)

    state = state_path |> File.read!() |> Jason.decode!()
    assert state["count"] == count
    assert state["last_ops"] == 0
    assert state["at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
  end

  test "second run_due is a no-op while growth since baseline stays under the trigger" do
    seed_bank()

    # first run writes the baseline
    assert Dream.run_due() == []
    # no growth since baseline → not due, still no claude call
    assert Dream.run_due() == []
  end

  test "a legacy _consolidation.json baseline migrates without a spurious pass", %{root: root} do
    seed_bank()
    count = length(Memory.bank_memories(@bank))

    # a pre-rename baseline: growth is already measured from the current count, so
    # the bank is not due — the migration must read it and fire zero ops.
    legacy = Path.join([root, @bank, "_consolidation.json"])
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    File.write!(legacy, Jason.encode!(%{"at" => now, "count" => count, "last_ops" => 0}))

    assert Dream.run_due() == []

    # state migrated to _dream.json; the legacy file is cleaned up
    dream = Path.join([root, @bank, "_dream.json"])
    assert File.exists?(dream)
    refute File.exists?(legacy)
    assert Jason.decode!(File.read!(dream))["count"] == count
  end
end
