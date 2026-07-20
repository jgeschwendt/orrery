defmodule Orrery.Watcher do
  @moduledoc """
  Watches `~/.claude/projects` (transcripts), `~/.claude/@memory` (banks), and
  `~/.claude/@log` (the log) and broadcasts coalesced change events over PubSub.
  LiveViews subscribe and re-render — no API/fetch/WebSocket glue.

  Topics:
    * `"transcripts"` → `{:session_changed, project, id}`
    * `"memory"`      → `:memory_changed`
    * `"log"`         → `:log_changed`
  """
  use GenServer

  alias Orrery.{Memory, Transcripts, UserLog}

  @debounce_ms 150

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    dirs =
      Enum.filter(
        [Transcripts.projects_dir(), Memory.memory_root(), UserLog.log_root()],
        &File.dir?/1
      )

    {:ok, watcher} = FileSystem.start_link(dirs: dirs)
    FileSystem.subscribe(watcher)
    {:ok, %{pending: MapSet.new(), timer: nil}}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    case classify(path) do
      nil -> {:noreply, state}
      event -> {:noreply, schedule(%{state | pending: MapSet.put(state.pending, event)})}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:flush, state) do
    Enum.each(state.pending, fn
      {:session_changed, _p, _id} = msg ->
        Phoenix.PubSub.broadcast(Orrery.PubSub, "transcripts", msg)

      :memory_changed ->
        Phoenix.PubSub.broadcast(Orrery.PubSub, "memory", :memory_changed)

      :log_changed ->
        Phoenix.PubSub.broadcast(Orrery.PubSub, "log", :log_changed)
    end)

    {:noreply, %{state | pending: MapSet.new(), timer: nil}}
  end

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, @debounce_ms)}

  defp schedule(state), do: state

  defp classify(path) do
    cond do
      String.ends_with?(path, ".jsonl") and String.contains?(path, "/.claude/projects/") ->
        case Path.split(Path.relative_to(path, Transcripts.projects_dir())) do
          [project, file | _] -> {:session_changed, project, Path.basename(file, ".jsonl")}
          _ -> nil
        end

      String.ends_with?(path, ".md") and String.starts_with?(path, UserLog.log_root()) ->
        :log_changed

      String.ends_with?(path, ".md") and String.starts_with?(path, Memory.memory_root()) ->
        :memory_changed

      true ->
        nil
    end
  end
end
