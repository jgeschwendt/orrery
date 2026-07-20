defmodule Orrery.RoutinesTest do
  use ExUnit.Case, async: true

  alias Orrery.Routines

  describe "parse_schedule_string/1 — interval" do
    test "every N unit → StartInterval seconds" do
      assert Routines.parse_schedule_string("every 6h") == %{
               "seconds" => 21_600,
               "type" => "interval"
             }

      assert Routines.parse_schedule_string("every 30m") == %{
               "seconds" => 1_800,
               "type" => "interval"
             }

      assert Routines.parse_schedule_string("every 90s") == %{
               "seconds" => 90,
               "type" => "interval"
             }
    end

    test "rejects zero / malformed intervals" do
      assert {:error, _} = Routines.parse_schedule_string("every 0h")
      assert {:error, _} = Routines.parse_schedule_string("every h")
    end
  end

  describe "parse_schedule_string/1 — cron" do
    test "a valid 5-field expr becomes a normalized cron map" do
      assert Routines.parse_schedule_string("0 9 * * *") == %{
               "expr" => "0 9 * * *",
               "type" => "cron"
             }

      # extra whitespace is normalized to single spaces
      assert Routines.parse_schedule_string("0   9-17  *  * 1-5") ==
               %{"expr" => "0 9-17 * * 1-5", "type" => "cron"}
    end

    test "weekday and month names are accepted" do
      assert %{"type" => "cron"} = Routines.parse_schedule_string("*/30 9-17 * * mon-fri")
      assert %{"type" => "cron"} = Routines.parse_schedule_string("0 0 1 jan *")
    end

    test "rejects wrong field count and out-of-range values" do
      assert {:error, _} = Routines.parse_schedule_string("0 9 * *")
      assert {:error, _} = Routines.parse_schedule_string("0 9 * * * *")
      assert {:error, _} = Routines.parse_schedule_string("0 25 * * *")
      assert {:error, _} = Routines.parse_schedule_string("60 9 * * *")
      assert {:error, _} = Routines.parse_schedule_string("bogus")
    end

    test "rejects an expr that would explode past the dict cap" do
      assert {:error, _} = Routines.parse_schedule_string("0-59 0-23 * * *")
    end
  end

  describe "cron_intervals/1 — launchd compilation" do
    test "constrained fields expand to the cartesian product, wildcards omitted" do
      assert {:ok, dicts} = Routines.cron_intervals("0 9-17 * * 1-5")
      assert length(dicts) == 45
      assert Enum.all?(dicts, &(Map.keys(&1) |> Enum.sort() == ["Hour", "Minute", "Weekday"]))
    end

    test "only the constrained field appears in each dict" do
      assert {:ok, [%{"Minute" => 0}, %{"Minute" => 30}]} =
               Routines.cron_intervals("*/30 * * * *")

      assert {:ok, [%{"Hour" => 9, "Minute" => 0}]} = Routines.cron_intervals("0 9 * * *")
    end

    test "weekday 7 folds to 0 (Sunday) and dedupes" do
      assert {:ok, [%{"Weekday" => 0}]} = Routines.cron_intervals("* * * * 7")
      assert {:ok, [%{"Weekday" => 0}]} = Routines.cron_intervals("* * * * 0,7")
    end

    test "all-wildcard yields a single empty dict (every minute)" do
      assert {:ok, [dict]} = Routines.cron_intervals("* * * * *")
      assert dict == %{}
    end

    test "a fully-constrained named-month expr expands to one dict" do
      assert {:ok, [%{"Day" => 1, "Hour" => 0, "Minute" => 0, "Month" => 1}]} =
               Routines.cron_intervals("0 0 1 jan *")
    end

    test "a step over the minute field expands to each stepped minute" do
      assert {:ok, dicts} = Routines.cron_intervals("5/15 * * * *")
      assert Enum.map(dicts, & &1["Minute"]) == [5, 20, 35, 50]
    end
  end

  describe "humanize_schedule/1" do
    test "interval seconds render as every-N" do
      assert Routines.humanize_schedule(%{"seconds" => 21_600, "type" => "interval"}) ==
               "every 6h"

      assert Routines.humanize_schedule(%{"seconds" => 1_800, "type" => "interval"}) ==
               "every 30m"
    end

    test "cron round-trips its expr" do
      sched = Routines.parse_schedule_string("0 9-17 * * 1-5")
      assert Routines.humanize_schedule(sched) == "0 9-17 * * 1-5"
    end

    test "unknown shape renders as a dash" do
      assert Routines.humanize_schedule(%{"nope" => true}) == "—"
    end

    test "a day of seconds renders in days, sub-minute stays in seconds" do
      assert Routines.humanize_schedule(%{"seconds" => 86_400, "type" => "interval"}) ==
               "every 1d"

      assert Routines.humanize_schedule(%{"seconds" => 45, "type" => "interval"}) ==
               "every 45s"
    end
  end
end
