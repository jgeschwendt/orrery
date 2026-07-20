defmodule OrreryWeb.UITest do
  use ExUnit.Case, async: true

  alias OrreryWeb.UI

  describe "rel_time/1" do
    test "nil and empty string render as empty" do
      assert UI.rel_time(nil) == ""
      assert UI.rel_time("") == ""
    end

    test "an unparseable timestamp renders as empty" do
      assert UI.rel_time("not-a-date") == ""
    end

    test "seconds ago bucket into just now / m / h / d" do
      now = DateTime.utc_now()

      assert UI.rel_time(iso_ago(now, 30)) == "just now"
      assert UI.rel_time(iso_ago(now, 120)) == "2m ago"
      assert UI.rel_time(iso_ago(now, 7200)) == "2h ago"
      assert UI.rel_time(iso_ago(now, 172_800)) == "2d ago"
    end
  end

  describe "collapse/2" do
    test "runs of whitespace collapse to single spaces" do
      assert UI.collapse("a   b\n c", 90) == "a b c"
    end

    test "non-binary input renders as empty" do
      assert UI.collapse(nil, 90) == ""
    end
  end

  describe "fmt_tokens/1" do
    test "sub-thousand renders as the integer" do
      assert UI.fmt_tokens(999) == "999"
    end

    test "thousands render with a k suffix and one decimal" do
      assert UI.fmt_tokens(1500) == "1.5k"
    end
  end

  describe "one_line/1" do
    test "command wins over query in the key precedence" do
      assert UI.one_line(%{"command" => "ls -la", "query" => "ignored"}) == "ls -la"
    end

    test "a map with no known key falls back to encoded JSON" do
      assert UI.one_line(%{"other" => "x"}) =~ "other"
    end

    test "a non-map renders as empty" do
      assert UI.one_line("nope") == ""
    end
  end

  describe "project_name/1" do
    test "returns the last path segment (leading dot preserved)" do
      assert UI.project_name("/Users/jlg/.claude") == ".claude"
    end
  end

  defp iso_ago(now, seconds),
    do: now |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()
end
