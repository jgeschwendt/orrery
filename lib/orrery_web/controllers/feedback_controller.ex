defmodule OrreryWeb.FeedbackController do
  use OrreryWeb, :controller

  # POST /feedback — accepts JSON `{"message": "..."}` or form-encoded `message`
  # (also `feedback`). Body is written to `~/.claude/@feedback/` for agents to act on.
  def create(conn, params) do
    message = params["message"] || params["feedback"] || ""

    case Orrery.Feedback.write(message, meta(conn)) do
      {:ok, path} ->
        conn
        |> put_status(:created)
        |> json(%{status: "ok", file: Path.basename(path)})

      {:error, :empty} ->
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", error: "`message` is required"})
    end
  end

  defp meta(conn) do
    %{
      remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    }
  end
end
