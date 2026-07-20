defmodule Orrery.Claude do
  @moduledoc """
  Shared runner for the unattended server-side `claude` CLI calls of the memory pipeline (extraction, judging, merge, the dream).

  Every run is `-p --output-format json --no-session-persistence` so pipeline runs
  never leave transcripts for the pipeline to later dissolve. `CLAUDE_MEMORY_PIPELINE=1`
  is exported on every call — the memory SessionEnd hook checks it and refuses to
  enqueue, so hooks firing inside `-p` runs (they do) can never feed the pipeline
  its own children.

  Structured output uses `--json-schema`: the CLI validates the reply and returns it
  under `structured_output` in the result JSON, which removes any need to substring-
  scrape JSON out of prose. Stdout can carry non-JSON noise lines (failing hooks print
  there), so parsing scans for the line whose JSON has `"type":"result"`.

  `:model` defaults to `sonnet`: extraction/judging must not inherit the user's
  premium default model — measured ~$0.25/call on the session default vs cents on
  sonnet, and the pipeline runs unattended on a schedule.
  """

  @default_model "sonnet"

  @doc """
  Run a prompt through the local `claude` CLI. Options:

    * `:schema` — JSON-schema map; the reply is validated by the CLI and returned
      decoded (the `structured_output`).
    * `:model` — model alias/id, default `#{inspect(@default_model)}`.

  Returns `{:ok, %{output: output, cost: usd}}` where `output` is the decoded
  structured output (when `:schema` given) or the result text, else
  `{:error, reason}`.
  """
  def run(prompt, opts \\ []) do
    # `:claude_runner` is the test seam: a 2-arity fun or a module with `run/2`
    # stands in for the real CLI so pipeline/judge tests never spend a claude call.
    # Unset (the production default) runs the real `System.cmd` path unchanged.
    case Application.get_env(:orrery, :claude_runner) do
      nil ->
        tmp = Path.join(System.tmp_dir!(), "claude_run_#{System.unique_integer([:positive])}.txt")
        File.write!(tmp, prompt)

        try do
          do_run(tmp, opts)
        after
          File.rm(tmp)
        end

      fun when is_function(fun, 2) ->
        fun.(prompt, opts)

      mod when is_atom(mod) ->
        mod.run(prompt, opts)
    end
  end

  defp do_run(tmp, opts) do
    claude = System.find_executable("claude") || "claude"
    schema = opts[:schema]

    # --setting-sources '' + --disable-slash-commands strip the user's settings,
    # plugins, and skill catalog from the run (~half the cost); the standard system
    # prompt is deliberately KEPT — it's prompt-cached across runs, and replacing it
    # via --system-prompt measured *more* expensive despite fewer input tokens.
    # (--bare would be leaner still but skips keychain reads → not logged in.)
    flags =
      ["-p", "--output-format", "json", "--no-session-persistence"] ++
        ["--setting-sources", "''", "--disable-slash-commands"] ++
        ["--model", opts[:model] || @default_model] ++
        if(schema, do: ["--json-schema", ~s("$CLAUDE_JSON_SCHEMA")], else: [])

    # The schema rides an env var so its quotes never meet the shell; the prompt rides
    # a file for the same reason (arbitrary text can't break `sh -c` quoting).
    env =
      [{"CLAUDE_MEMORY_PIPELINE", "1"}] ++
        if(schema, do: [{"CLAUDE_JSON_SCHEMA", Jason.encode!(schema)}], else: [])

    {out, code} =
      System.cmd("sh", ["-c", ~s('#{claude}' #{Enum.join(flags, " ")} < '#{tmp}')], env: env)

    with {:ok, result} <- find_result(out, code) do
      cost = result["total_cost_usd"] || 0.0

      cond do
        result["is_error"] -> {:error, {:claude, result["result"]}}
        schema -> {:ok, %{output: result["structured_output"], cost: cost}}
        true -> {:ok, %{output: result["result"], cost: cost}}
      end
    end
  end

  # Stdout may interleave hook noise with the result JSON — scan for the result line.
  defp find_result(out, code) do
    out
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "result"} = r} -> {:ok, r}
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, {:exit, code, String.slice(out, 0, 500)}}
      ok -> ok
    end
  end
end
