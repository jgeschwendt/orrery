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

# Disable/enable exercises the routines.json flag persistence and the guards only —
# never the launchd side. It points :routines_dir at a tmp dir (async: false, restored
# in on_exit so pages_smoke_test and the real dir are untouched) and drives the pure
# helpers. The full enable/1 is NOT called: install_agent writes a plist into
# ~/Library/LaunchAgents and bootstraps it. disable/1 IS safe for a never-installed
# slug — loaded?/1 is non-zero (→ no bootout) and File.rm of the absent plist is enoent.
defmodule Orrery.RoutinesDisableTest do
  use ExUnit.Case, async: false

  alias Orrery.Routines

  setup do
    prev = Application.get_env(:orrery, :routines_dir)
    tmp = Path.join(System.tmp_dir!(), "orrery-routines-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:orrery, :routines_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:orrery, :routines_dir, prev),
        else: Application.delete_env(:orrery, :routines_dir)

      File.rm_rf!(tmp)
    end)

    # A unique slug guarantees plist_path/1 (which lives under ~/Library/LaunchAgents,
    # NOT the tmp dir) can never collide with a real installed routine.
    slug = "test-disable-#{System.unique_integer([:positive])}"

    File.write!(
      Path.join(tmp, "routines.json"),
      Jason.encode!([
        %{
          "name" => "Seed",
          "prompt" => "do the thing",
          "schedule" => %{"seconds" => 3600, "type" => "interval"},
          "slug" => slug
        }
      ])
    )

    %{slug: slug}
  end

  test "put_disabled/2 true persists the flag; get/1 and list/0 surface it", %{slug: slug} do
    assert %{"disabled" => true} = Routines.put_disabled(slug, true)
    assert Routines.get(slug)["disabled"] == true

    row = Enum.find(Routines.list(), &(&1["slug"] == slug))
    assert row["disabled"] == true
  end

  test "list/0 normalizes an absent flag to the boolean false", %{slug: slug} do
    row = Enum.find(Routines.list(), &(&1["slug"] == slug))
    assert row["disabled"] == false
  end

  test "put_disabled/2 false drops the key entirely (enable's persistence half)", %{slug: slug} do
    Routines.put_disabled(slug, true)
    routine = Routines.put_disabled(slug, false)
    refute Map.has_key?(routine, "disabled")
    refute Map.has_key?(Routines.get(slug), "disabled")
  end

  test "disable/1 persists the flag (launchd calls are safe no-ops here)", %{slug: slug} do
    assert Routines.disable(slug) == :ok
    assert Routines.get(slug)["disabled"] == true
  end

  test "run_now/1 refuses a disabled routine before any launchctl call", %{slug: slug} do
    Routines.put_disabled(slug, true)
    assert Routines.run_now(slug) == {:error, :disabled}
  end

  test "disable/enable reject an unknown slug and an unsafe path component", %{slug: _slug} do
    assert Routines.disable("no-such-routine") == {:error, "routine not found"}
    assert Routines.enable("no-such-routine") == {:error, "routine not found"}
    assert Routines.disable("../evil") == {:error, :invalid_slug}
    assert Routines.enable("../evil") == {:error, :invalid_slug}
  end

  test "update/2 preserves the disabled flag and skips materialization", %{slug: slug} do
    Routines.put_disabled(slug, true)

    assert {:ok, routine} =
             Routines.update(slug, %{
               "name" => "Renamed",
               "prompt" => "changed",
               "schedule" => "every 12h"
             })

    assert routine["disabled"] == true
    assert routine["name"] == "Renamed"
    assert Routines.get(slug)["disabled"] == true
    # install_agent was skipped — nothing materialized into the tmp routines dir.
    refute File.exists?(Routines.script_path(slug))
  end
end
