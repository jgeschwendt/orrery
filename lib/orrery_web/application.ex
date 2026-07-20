defmodule OrreryWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OrreryWeb.Telemetry,
      {Phoenix.PubSub, name: Orrery.PubSub},
      Orrery.Watcher,
      {Task.Supervisor, name: Orrery.Memory.Pipeline.TaskSup},
      Orrery.Memory.Pipeline,
      OrreryWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OrreryWeb.Supervisor)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OrreryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
