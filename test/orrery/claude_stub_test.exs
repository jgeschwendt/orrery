defmodule Orrery.ClaudeStubTest do
  use ExUnit.Case, async: false

  alias Orrery.Claude

  # The seam must never reach the real CLI: a sentinel return proves the stub
  # ran, and setting `claude` to a path that would crash `System.cmd` guards
  # against a silent fall-through to the real path.

  setup do
    on_exit(fn -> Application.delete_env(:orrery, :claude_runner) end)
    :ok
  end

  test "a 2-arity fun receives the prompt and opts and its return is passed through" do
    parent = self()

    Application.put_env(:orrery, :claude_runner, fn prompt, opts ->
      send(parent, {:ran, prompt, opts})
      {:ok, %{output: "from-fun", cost: 0.0}}
    end)

    assert Claude.run("hello", model: "haiku") == {:ok, %{output: "from-fun", cost: 0.0}}
    assert_received {:ran, "hello", [model: "haiku"]}
  end

  test "a module dispatches to its run/2" do
    Application.put_env(:orrery, :claude_runner, Orrery.ClaudeStubTest.StubRunner)

    assert Claude.run("world", []) == {:ok, %{output: "from-module", cost: 0.0}}
  end
end

defmodule Orrery.ClaudeStubTest.StubRunner do
  def run(_prompt, _opts), do: {:ok, %{output: "from-module", cost: 0.0}}
end
