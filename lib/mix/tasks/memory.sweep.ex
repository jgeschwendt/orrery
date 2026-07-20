defmodule Mix.Tasks.Memory.Sweep do
  @shortdoc "Run the automatic memory sweep (dissolve idle sessions, drain inbox, dream)"

  @moduledoc """
  Entry point for the "Memory sweep" launchd routine:

      cd ~/GitHub/jgeschwendt/orrery && ~/.local/bin/mise exec -- mix memory.sweep [--max N]

  Runs `Orrery.Memory.Sweep.run/1` without starting the web supervision tree (no
  endpoint, no port bind — safe alongside a running dev server).
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [max: :integer])

    Mix.Task.run("compile")
    Application.ensure_all_started([:jason, :crypto])

    case Orrery.Memory.Sweep.run(opts) do
      :locked -> Mix.shell().info("sweep: another sweep is already running — skipped")
      report -> print(report)
    end
  end

  defp print(report) do
    Mix.shell().info("sweep: " <> Orrery.Memory.Sweep.summary_line(report))

    Enum.each(report.queue ++ report.results, fn r ->
      Mix.shell().info("  #{r.outcome} · #{r.memories} memories · #{r.title} (#{r.id})")
    end)

    Enum.each(report.dreamt, fn c ->
      Mix.shell().info("  dreamt #{c.bank}: #{length(c.ops)} op(s)")
    end)
  end
end
