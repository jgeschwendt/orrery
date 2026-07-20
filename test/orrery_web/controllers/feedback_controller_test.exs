defmodule OrreryWeb.FeedbackControllerTest do
  use OrreryWeb.ConnCase, async: false

  setup do
    tmp = Path.join(System.tmp_dir!(), "feedback-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:orrery, :feedback_root, tmp)

    on_exit(fn ->
      Application.delete_env(:orrery, :feedback_root)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "POST /feedback persists the message and returns 201", %{conn: conn, tmp: tmp} do
    conn = post(conn, ~p"/feedback", %{"message" => "the dashboard mislabels X"})

    assert %{"status" => "ok", "file" => file} = json_response(conn, 201)

    path = Path.join(tmp, file)
    assert File.exists?(path)

    contents = File.read!(path)
    assert contents =~ "the dashboard mislabels X"
    assert contents =~ "received_at:"
  end

  test "POST /feedback with a blank message returns 400 and writes nothing", %{
    conn: conn,
    tmp: tmp
  } do
    conn = post(conn, ~p"/feedback", %{"message" => "   "})

    assert json_response(conn, 400) == %{"status" => "error", "error" => "`message` is required"}
    assert File.ls!(tmp) == []
  end

  test "POST /feedback accepts the `feedback` param alias", %{conn: conn} do
    conn = post(conn, ~p"/feedback", %{"feedback" => "via the alias"})

    assert %{"status" => "ok"} = json_response(conn, 201)
  end
end
