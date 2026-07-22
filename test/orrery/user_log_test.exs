defmodule Orrery.UserLogTest do
  # async: false — the list_days/1 test overrides the :orrery/:log_root application env
  # (a global), so it cannot run concurrently with other cases touching the same env.
  use ExUnit.Case, async: false

  alias Orrery.UserLog

  describe "weekday/1" do
    test "an ISO date resolves to its weekday name" do
      assert UserLog.weekday("2026-07-19") == "Sunday"
    end

    test "an unparseable date renders as empty" do
      assert UserLog.weekday("nope") == ""
    end
  end

  describe "get_day/1" do
    test "a path-traversal key returns the empty day shape" do
      assert %{archived: [], conversations: [], notes: "", voyage: "", weekday: ""} =
               UserLog.get_day("../../etc/passwd")
    end
  end

  describe "list_days/1" do
    test "unions voyage pages and session days newest-first, flagging logged? and preview" do
      root = Path.join(System.tmp_dir!(), "user_log_days_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Application.put_env(:orrery, :log_root, root)
      Application.put_env(:orrery, :archive_root, Path.join(root, "archive"))
      on_exit(fn -> Application.delete_env(:orrery, :log_root) end)
      on_exit(fn -> Application.delete_env(:orrery, :archive_root) end)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "2026-07-18.voyage.md"), """
      ---
      date: 2026-07-18
      type: voyage
      ---
      # heading
      The prose line.
      """)

      days = UserLog.list_days([%{updated_at: "2026-07-17T12:00:00Z"}])

      assert Enum.map(days, & &1.date) == ["2026-07-18", "2026-07-17"]

      voyage_day = Enum.find(days, &(&1.date == "2026-07-18"))
      assert voyage_day.logged? == true
      assert voyage_day.preview == "The prose line."

      session_day = Enum.find(days, &(&1.date == "2026-07-17"))
      assert session_day.logged? == false
    end
  end
end
