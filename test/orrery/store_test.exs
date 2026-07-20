defmodule Orrery.StoreTest do
  use ExUnit.Case, async: true

  describe "component?/1" do
    test "accepts plain filename segments" do
      assert Orrery.Store.component?("abc")
      assert Orrery.Store.component?("2026-07-03")
      assert Orrery.Store.component?("feedback_deploy_process.md")
      assert Orrery.Store.component?("-Users-jlg--claude")
    end

    test "rejects traversal, separators, and non-strings" do
      refute Orrery.Store.component?("..")
      refute Orrery.Store.component?(".")
      refute Orrery.Store.component?("")
      refute Orrery.Store.component?("../etc")
      refute Orrery.Store.component?("a/b")
      refute Orrery.Store.component?("a\0b")
      refute Orrery.Store.component?(nil)
      refute Orrery.Store.component?(123)
    end
  end

  test "write!/2 replaces atomically and leaves no temp files" do
    dir = Path.join(System.tmp_dir!(), "store_test_#{System.unique_integer([:positive])}")
    path = Path.join(dir, "f.json")
    Orrery.Store.write!(path, "one")
    Orrery.Store.write!(path, "two")
    assert File.read!(path) == "two"
    assert File.ls!(dir) == ["f.json"]
    File.rm_rf!(dir)
  end
end
