defmodule OrreryWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [OrreryWeb.Telemetry, {Phoenix.PubSub, name: Orrery.PubSub}] ++
        pipeline_children() ++
        [OrreryWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: OrreryWeb.Supervisor)
  end

  # The filesystem Watcher, the pipeline Task.Supervisor, and the pipeline worker are the
  # app's globally-named, side-effecting singletons. `:test` gates them out (config/test.exs
  # sets `start_pipeline?: false`): a shared singleton's async work interleaves with each
  # test's `Application.put_env(:memory_root, tmp)` override and can resolve a write against
  # the real ~/.claude ledger mid-flight. Tests start their own isolated, torn-down instances.
  defp pipeline_children do
    if Application.get_env(:orrery, :start_pipeline?, true) do
      [
        Orrery.Watcher,
        {Task.Supervisor, name: Orrery.Memory.Pipeline.TaskSup},
        Orrery.Memory.Pipeline
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OrreryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
