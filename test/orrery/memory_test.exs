defmodule Orrery.MemoryTest do
  use ExUnit.Case, async: false

  alias Orrery.Memory

  @bank "-tmp-project"

  setup do
    root = Path.join(System.tmp_dir!(), "memory_test_#{System.unique_integer([:positive])}")
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

  defp msg(role, text, opts \\ []) do
    %{
      blocks: [%{kind: "text", text: text}],
      is_meta: Keyword.get(opts, :is_meta, false),
      is_sidechain: Keyword.get(opts, :is_sidechain, false),
      role: role
    }
  end

  describe "flatten/1" do
    test "drops sidechain messages, keeps normal ones" do
      session = %{
        messages: [
          msg("user", "NORMAL_TEXT"),
          msg("assistant", "SIDECHAIN_SECRET", is_sidechain: true)
        ]
      }

      out = Memory.flatten(session)
      assert out =~ "NORMAL_TEXT"
      refute out =~ "SIDECHAIN_SECRET"
    end

    test "over-60k text keeps head and tail with a middle-truncation marker" do
      session = %{
        messages: [
          msg("user", "FIRSTUNIQUE" <> String.duplicate("a", 40_000)),
          msg("user", String.duplicate("b", 40_000) <> "LASTUNIQUE")
        ]
      }

      out = Memory.flatten(session)
      assert out =~ "FIRSTUNIQUE"
      assert out =~ "LASTUNIQUE"
      assert out =~ "[middle truncated]"
      assert String.length(out) <= 60_100
    end

    test "a conversation at or under 60k is untouched" do
      session = %{messages: [msg("user", "just a short line")]}
      out = Memory.flatten(session)
      refute out =~ "[middle truncated]"
      assert out == "### user\njust a short line"
    end
  end

  test "commit stamps created/updated and round-trips them", %{root: root} do
    :ok = commit(%{})

    [m] = Memory.bank_memories(@bank)
    assert m.created != nil
    assert m.updated == m.created
    assert File.exists?(Path.join([root, @bank, "reference_a_fact.md"]))
  end

  test "supersede archives the old file and inherits its created", %{root: root} do
    :ok = commit(%{name: "Old fact", body: "v1"})
    [old] = Memory.bank_memories(@bank)

    :ok = commit(%{name: "New fact", body: "v2", replaces: [old.file]})

    [new] = Memory.bank_memories(@bank)
    assert new.name == "New fact"
    assert new.created == old.created

    archived = File.ls!(Path.join([root, @bank, "_archive"]))
    assert [archived_file] = archived
    assert String.ends_with?(archived_file, "_" <> old.file)
  end

  test "slug collision gets a numeric suffix instead of clobbering", %{root: root} do
    :ok = commit(%{name: "Deploy process", body: "first"})
    :ok = commit(%{name: "Deploy Process!", body: "second"})

    files = root |> Path.join(@bank) |> File.ls!() |> Enum.filter(&(&1 =~ ~r/^reference_/))
    assert Enum.sort(files) == ["reference_deploy_process.md", "reference_deploy_process_2.md"]
    assert length(Memory.bank_memories(@bank)) == 2
  end

  test "re-committing the same memory (edit) replaces in place via replaces" do
    :ok = commit(%{body: "v1"})
    [m1] = Memory.bank_memories(@bank)
    :ok = commit(%{body: "v2", replaces: [m1.file]})

    [m2] = Memory.bank_memories(@bank)
    assert m2.body == "v2"
    assert m2.created == m1.created
  end

  test "delete_memory archives rather than destroys", %{root: root} do
    :ok = commit(%{})
    [m] = Memory.bank_memories(@bank)

    Memory.delete_memory(@bank, m.file)

    assert Memory.bank_memories(@bank) == []
    assert [_] = File.ls!(Path.join([root, @bank, "_archive"]))
  end

  test "recall frontmatter key round-trips through commit and parse", %{root: root} do
    :ok = commit(%{name: "Pinned fact", recall: "pin"})

    [pinned] = Memory.bank_memories(@bank)
    assert pinned.recall == "pin"
    assert File.read!(Path.join([root, @bank, "reference_pinned_fact.md"])) =~ "recall: pin"

    :ok = commit(%{name: "Plain fact"})

    [plain] = @bank |> Memory.bank_memories() |> Enum.filter(&(&1.name == "Plain fact"))
    assert plain.recall == nil
    refute File.read!(Path.join([root, @bank, "reference_plain_fact.md"])) =~ "recall:"
  end

  test "staging carries recall end-to-end: valid kept, junk nil'd, commit writes it", %{
    root: root
  } do
    staging = [
      %{
        bank: @bank,
        body: "b",
        description: "d",
        name: "Pinned staged",
        recall: "pin",
        replaces: nil,
        source: nil,
        type: "reference"
      },
      %{
        bank: @bank,
        body: "b",
        description: "d",
        name: "Bogus staged",
        recall: "bogus",
        replaces: nil,
        source: nil,
        type: "reference"
      }
    ]

    File.write!(Path.join(root, ".staging.json"), Jason.encode!(staging))

    staged = Memory.read_staging()
    pinned = Enum.find(staged, &(&1.name == "Pinned staged"))
    bogus = Enum.find(staged, &(&1.name == "Bogus staged"))
    assert pinned.recall == "pin"
    assert bogus.recall == nil

    :ok = Memory.commit_memory(pinned)
    assert File.read!(Path.join([root, @bank, "reference_pinned_staged.md"])) =~ "recall: pin"
  end

  test "staging normalizes replaces: non-list nil'd, list filtered to non-empty binaries", %{
    root: root
  } do
    staging = [
      %{
        bank: @bank,
        body: "b",
        description: "d",
        name: "Empty string replaces",
        recall: nil,
        replaces: "",
        source: nil,
        type: "reference"
      },
      %{
        bank: @bank,
        body: "b",
        description: "d",
        name: "Junky list replaces",
        recall: nil,
        replaces: ["a.md", "", 42],
        source: nil,
        type: "reference"
      },
      %{
        bank: @bank,
        body: "b",
        description: "d",
        name: "Valid list replaces",
        recall: nil,
        replaces: ["b.md"],
        source: nil,
        type: "reference"
      }
    ]

    File.write!(Path.join(root, ".staging.json"), Jason.encode!(staging))

    staged = Memory.read_staging()
    empty = Enum.find(staged, &(&1.name == "Empty string replaces"))
    junky = Enum.find(staged, &(&1.name == "Junky list replaces"))
    valid = Enum.find(staged, &(&1.name == "Valid list replaces"))
    assert empty.replaces == nil
    assert junky.replaces == ["a.md"]
    assert valid.replaces == ["b.md"]
  end

  test "unwritable banks are refused" do
    assert {:error, :not_writable} = commit(%{bank: "auto:whatever"})
    assert {:error, :not_writable} = commit(%{bank: "../escape"})
  end

  test "MEMORY.md index regenerates and stays within the entry cap", %{root: root} do
    :ok = commit(%{})
    index = File.read!(Path.join([root, @bank, "MEMORY.md"]))
    assert index =~ "[A fact](reference_a_fact.md)"
  end

  test "archived_memories lists the archive newest-first with archived_at" do
    :ok = commit(%{name: "Old fact", body: "v1"})
    [old] = Memory.bank_memories(@bank)
    :ok = commit(%{name: "New fact", body: "v2", replaces: [old.file]})

    assert [a] = Memory.archived_memories(@bank)
    assert a.name == "Old fact"
    assert a.archived_at =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
  end

  test "restore_memory re-commits and consumes the archive entry", %{root: root} do
    :ok = commit(%{})
    [m] = Memory.bank_memories(@bank)
    Memory.delete_memory(@bank, m.file)
    [a] = Memory.archived_memories(@bank)

    assert :ok = Memory.restore_memory(@bank, a.file)

    assert [restored] = Memory.bank_memories(@bank)
    assert restored.name == m.name
    assert restored.created == m.created
    assert Memory.archived_memories(@bank) == []
    assert File.read!(Path.join([root, @bank, "MEMORY.md"])) =~ m.name
  end

  test "restore_memory refuses unwritable banks and bad paths" do
    assert {:error, :not_found} = Memory.restore_memory("auto:x", "f.md")
    assert {:error, :not_found} = Memory.restore_memory(@bank, "../escape.md")
    assert {:error, :not_found} = Memory.restore_memory(@bank, "missing.md")
  end

  test "drain_inbox keeps entries whose bank is unwritable", %{root: root} do
    staging = [
      %{
        bank: "auto:x",
        body: "b",
        description: "d",
        name: "n",
        replaces: nil,
        source: nil,
        type: "user"
      }
    ]

    File.write!(Path.join(root, ".staging.json"), Jason.encode!(staging))

    # "auto:" banks are read-only — the entry never reaches the judge but is kept staged
    assert %{committed: 0, dropped: 0, kept: 1} = Memory.drain_inbox()
  end

  defp stage!(root, entries) do
    File.write!(Path.join(root, ".staging.json"), Jason.encode!(entries))
  end

  defp staged_entry(attrs) do
    Map.merge(
      %{
        bank: @bank,
        body: "b",
        description: "d",
        name: "n",
        recall: nil,
        replaces: nil,
        source: nil,
        type: "reference"
      },
      attrs
    )
  end

  defp stub_judge(fun) do
    Application.put_env(:orrery, :claude_runner, fun)
    on_exit(fn -> Application.delete_env(:orrery, :claude_runner) end)
  end

  test "drain_inbox archives judge-dropped entries instead of destroying them", %{root: root} do
    stub_judge(fn _prompt, _opts ->
      {:ok,
       %{output: %{"verdicts" => [%{"name" => "Droppable fact", "verdict" => "drop"}]}, cost: 0.0}}
    end)

    stage!(root, [staged_entry(%{body: "drop me body", name: "Droppable fact", type: "feedback"})])

    result = Memory.drain_inbox()
    assert result.committed == 0
    assert result.dropped == 1
    assert Memory.read_staging() == []

    archive_dir = Path.join([root, @bank, "_archive"])
    assert [file] = File.ls!(archive_dir)
    assert file =~ ~r/^\d{8}T\d{6}_feedback_droppable_fact\.md$/

    assert [a] = Memory.archived_memories(@bank)
    assert a.name == "Droppable fact"
    assert a.type == "feedback"
    assert a.body == "drop me body"
  end

  test "drain_inbox outcomes tag committed and dropped entries", %{root: root} do
    stub_judge(fn _prompt, _opts ->
      {:ok,
       %{
         output: %{
           "verdicts" => [
             %{"name" => "Keeper", "verdict" => "commit", "replaces" => []},
             %{"name" => "Loser", "verdict" => "drop"}
           ]
         },
         cost: 0.0
       }}
    end)

    stage!(root, [staged_entry(%{name: "Keeper"}), staged_entry(%{name: "Loser"})])

    result = Memory.drain_inbox()
    assert result.committed == 1
    assert result.dropped == 1

    assert Enum.sort_by(result.outcomes, & &1.name) == [
             %{bank: @bank, name: "Keeper", outcome: "committed"},
             %{bank: @bank, name: "Loser", outcome: "dropped"}
           ]

    assert [committed] = Memory.bank_memories(@bank)
    assert committed.name == "Keeper"
  end

  test "drain_inbox keeps and tags entries when the judge is unavailable", %{root: root} do
    stub_judge(fn _prompt, _opts -> {:error, :boom} end)

    stage!(root, [staged_entry(%{name: "Kept one"}), staged_entry(%{name: "Kept two"})])

    result = Memory.drain_inbox()

    assert result == %{
             committed: 0,
             dropped: 0,
             kept: 2,
             outcomes: [
               %{bank: @bank, name: "Kept one", outcome: "kept"},
               %{bank: @bank, name: "Kept two", outcome: "kept"}
             ]
           }

    assert length(Memory.read_staging()) == 2
  end

  test "punctuation-only names fall back to distinct x<digest> slugs", %{root: root} do
    :ok = commit(%{name: "!!!"})
    :ok = commit(%{name: "@@@"})

    names = @bank |> Memory.bank_memories() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["!!!", "@@@"]

    files = root |> Path.join(@bank) |> File.ls!() |> Enum.filter(&(&1 =~ ~r/^reference_/))
    assert length(files) == 2
    assert Enum.all?(files, &(&1 =~ ~r/^reference_x[0-9a-f]{8}\.md$/))
    assert files |> Enum.uniq() |> length() == 2
  end
end
