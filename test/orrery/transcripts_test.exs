defmodule Orrery.TranscriptsTest do
  # async: false — the session_cwds/0 test overrides the :orrery/:projects_dir application
  # env (a global), so it cannot run concurrently with other cases touching the same env.
  use ExUnit.Case, async: false

  alias Orrery.Transcripts

  setup do
    file =
      Path.join(System.tmp_dir!(), "transcripts_test_#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(file) end)
    %{fixture: file}
  end

  defp write_lines(file, objects) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Enum.map_join(objects, "\n", &Jason.encode!/1))
  end

  test "consecutive user prefixes collapse to the final resubmission", %{fixture: file} do
    write_lines(file, [
      %{
        "type" => "user",
        "message" => %{"role" => "user", "content" => "Hello"},
        "timestamp" => "2026-07-19T10:00:00Z"
      },
      %{
        "type" => "user",
        "message" => %{"role" => "user", "content" => "Hello world"},
        "timestamp" => "2026-07-19T10:00:01Z"
      }
    ])

    session = Transcripts.parse_session(file, nil)

    assert session.message_count == 1
    assert [%{blocks: [%{kind: "text", text: "Hello world"}]}] = session.messages
  end

  test "a command-name message is meta and usage accumulates across assistants", %{fixture: file} do
    write_lines(file, [
      %{
        "type" => "user",
        "message" => %{"role" => "user", "content" => "<command-name>foo</command-name>"},
        "timestamp" => "2026-07-19T10:00:00Z"
      },
      %{
        "type" => "assistant",
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "one"}],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        },
        "timestamp" => "2026-07-19T10:00:01Z"
      },
      %{
        "type" => "assistant",
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "two"}],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
        },
        "timestamp" => "2026-07-19T10:00:02Z"
      }
    ])

    session = Transcripts.parse_session(file, nil)

    # the command-name user message is meta → excluded from the count; two assistants remain
    assert session.message_count == 2
    assert session.tokens.input == 13
    assert session.tokens.output == 7
  end

  test "session_cwds/0 takes the first cwd seen per transcript and drops cwd-less ones" do
    root = Path.join(System.tmp_dir!(), "transcripts_cwds_#{System.unique_integer([:positive])}")
    Application.put_env(:orrery, :projects_dir, root)
    on_exit(fn -> Application.delete_env(:orrery, :projects_dir) end)
    on_exit(fn -> File.rm_rf!(root) end)

    # proj-a: cwd on the very first line.
    write_lines(Path.join([root, "proj-a", "s1.jsonl"]), [
      %{"type" => "user", "cwd" => "/tmp/a", "message" => %{"content" => "hi"}}
    ])

    # proj-b: no cwd on the first line, cwd on a later line (locks scan-through).
    write_lines(Path.join([root, "proj-b", "s2.jsonl"]), [
      %{"type" => "user", "message" => %{"content" => "hi"}},
      %{"type" => "user", "cwd" => "/tmp/b", "message" => %{"content" => "again"}}
    ])

    # proj-c: no cwd anywhere (locks the drop).
    write_lines(Path.join([root, "proj-c", "s3.jsonl"]), [
      %{"type" => "user", "message" => %{"content" => "hi"}}
    ])

    assert Enum.sort(Transcripts.session_cwds()) == ["/tmp/a", "/tmp/b"]
  end
end
