defmodule Orrery.Routines do
  @moduledoc """
  User-defined scheduled routines, each backed by its own macOS launchd
  LaunchAgent. A routine is a name + a schedule + either an unattended `claude`
  prompt or a plain shell `command` (for jobs like the memory sweep where a full
  claude session would be waste); it is stored in
  `/Users/jlg/GitHub/jgeschwendt/orrery/data/@routines/routines.json`
  and materialized as `<slug>.sh` / `<slug>.prompt.txt` / `com.claude.routines.<slug>.plist`.

  launchd *is* the scheduler — nothing runs inside the BEAM. This module reads and
  manages the agents through `launchctl`, mirroring `Orrery.Memory`'s habit of
  shelling out to `claude` and keeping plain files under
  `/Users/jlg/GitHub/jgeschwendt/livebook/data`.
  """

  @default_update_prompt """
  You are running UNATTENDED on a schedule — no human is watching, so never wait for input or ask questions.

  For each tool below: read the installed version, then the latest released version. If they match, do nothing. If a newer version exists, FETCH its changelog for the gap between installed and latest and assess risk. Apply the update ONLY when the changelog shows no breaking changes; if it shows a breaking change, SKIP the update and log one line explaining why. Print a one-line result per tool.

  - claude (Claude Code)
    installed:  claude --version
    latest:     curl -fsSL https://downloads.claude.ai/claude-code-releases/latest
    changelog:  https://raw.githubusercontent.com/anthropics/claude-code/refs/heads/main/CHANGELOG.md
    update:     claude update

  - mise
    installed:  mise version
    latest:     https://api.github.com/repos/jdx/mise/releases/latest (the tag_name field)
    changelog:  https://github.com/jdx/mise/releases/tag/<tag_name>
    update:     mise self-update --yes\
  """

  @default_routines [
    %{
      "command" => "cd $HOME/.claude && $HOME/.local/bin/mise exec -- mix memory.sweep",
      "name" => "Memory sweep",
      "schedule" => %{"seconds" => 3600, "type" => "interval"},
      "slug" => "memory-sweep"
    },
    %{
      "name" => "Update tools",
      "prompt" => @default_update_prompt,
      "schedule" => %{"seconds" => 21_600, "type" => "interval"},
      "slug" => "update"
    }
  ]

  # Built at runtime so the voyage log carries `Orrery.UserLog`'s live prompt — the
  # same one the dashboard's "dream now" button runs. launchd fires it nightly, unattended.
  defp default_routines do
    @default_routines ++
      [
        %{
          "name" => "Voyage log",
          "prompt" => Orrery.UserLog.voyage_prompt(),
          "schedule" => %{"expr" => "30 23 * * *", "type" => "cron"},
          "slug" => "voyage-log"
        }
      ]
  end

  @units %{"d" => 86_400, "h" => 3600, "m" => 60, "s" => 1}

  # Cron field name aliases (standard): weekday sun–sat (Sunday = 0; launchd also
  # reads 7 as Sunday) and month jan–dec (January = 1).
  @dow_names for {n, i} <- Enum.with_index(~w(sun mon tue wed thu fri sat)), into: %{}, do: {n, i}
  @month_names for {n, i} <-
                     Enum.with_index(~w(jan feb mar apr may jun jul aug sep oct nov dec)),
                   into: %{},
                   do: {n, i + 1}

  # Upper bound on StartCalendarInterval dicts one cron expr may expand to, so an expr
  # that enumerates many constrained fields (e.g. `0-59 0-23 * * *` → 60×24) fails loudly
  # instead of emitting thousands of launchd entries. Wildcard fields are omitted, not
  # enumerated, so `* 9-17 * * 1-5` is only 45 dicts (fires every minute in-window).
  @cron_max_dicts 500

  # ── definitions store ─────────────────────────────────────
  def list do
    Enum.map(read_routines(), fn r ->
      slug = r["slug"]

      Map.merge(r, %{
        "installed" => File.exists?(plist_path(slug)),
        "last_run" => last_run(slug),
        "loaded" => loaded?(slug)
      })
    end)
  end

  def get(slug), do: Enum.find(read_routines(), &(&1["slug"] == slug))

  @doc "Validate params, persist a new routine, and load its agent."
  def create(params) do
    with {:ok, attrs} <- validate(params) do
      slug = slugify(attrs.name)

      if Enum.any?(read_routines(), &(&1["slug"] == slug)) do
        {:error, "a routine named “#{attrs.name}” already exists"}
      else
        routine =
          %{"name" => attrs.name, "schedule" => attrs.schedule, "slug" => slug}
          |> Map.merge(attrs.run)

        write_routines(read_routines() ++ [routine])
        install_agent(routine)
        {:ok, routine}
      end
    end
  end

  @doc "Update an existing routine (slug stays fixed) and reload its agent."
  def update(slug, params) do
    with {:ok, attrs} <- validate(params) do
      routines = read_routines()

      case Enum.find(routines, &(&1["slug"] == slug)) do
        nil ->
          {:error, "routine not found"}

        old ->
          routine =
            old
            |> Map.drop(["command", "prompt"])
            |> Map.merge(%{"name" => attrs.name, "schedule" => attrs.schedule})
            |> Map.merge(attrs.run)

          write_routines(Enum.map(routines, &if(&1["slug"] == slug, do: routine, else: &1)))
          install_agent(routine)
          {:ok, routine}
      end
    end
  end

  @doc "Unload + remove a routine and all of its files."
  def delete(slug) do
    if Orrery.Store.component?(slug) do
      if loaded?(slug), do: bootout(slug)

      Enum.each(
        [
          plist_path(slug),
          script_path(slug),
          prompt_path(slug),
          result_path(slug),
          log_path(slug)
        ],
        &File.rm/1
      )

      write_routines(Enum.reject(read_routines(), &(&1["slug"] == slug)))
      :ok
    else
      {:error, :invalid_slug}
    end
  end

  @doc "Force a routine to run now, loading its agent first if needed."
  def run_now(slug) do
    if Orrery.Store.component?(slug) do
      if (r = get(slug)) && not loaded?(slug), do: install_agent(r)

      {out, code} =
        System.cmd("launchctl", ["kickstart", "-k", service(slug)], stderr_to_stdout: true)

      if code == 0, do: :ok, else: {:error, String.trim(out)}
    else
      {:error, :invalid_slug}
    end
  end

  # ── form params <-> schedule ──────────────────────────────
  def new_form_params,
    do: %{"command" => "", "name" => "", "prompt" => "", "schedule" => "every 6h"}

  def to_form_params(r),
    do: %{
      "command" => r["command"] || "",
      "name" => r["name"],
      "prompt" => r["prompt"] || "",
      "schedule" => humanize_schedule(r["schedule"])
    }

  def schedule_label(schedule), do: humanize_schedule(schedule)

  def humanize_schedule(%{"type" => "interval", "seconds" => s}) when is_integer(s) do
    cond do
      rem(s, 86_400) == 0 -> "every #{div(s, 86_400)}d"
      rem(s, 3600) == 0 -> "every #{div(s, 3600)}h"
      rem(s, 60) == 0 -> "every #{div(s, 60)}m"
      true -> "every #{s}s"
    end
  end

  # Cron is the canonical calendar form — humanize round-trips the stored expr.
  def humanize_schedule(%{"type" => "cron", "expr" => expr}), do: expr

  def humanize_schedule(_), do: "—"

  # ── status helpers ────────────────────────────────────────
  def label(slug), do: "com.claude.routines.#{slug}"
  def script_path(slug), do: Path.join(routines_dir(), "#{slug}.sh")
  def log_path(slug), do: Path.join(routines_dir(), "#{slug}.log")
  def plist_path(slug), do: Path.join(home(), "Library/LaunchAgents/#{label(slug)}.plist")

  def loaded?(slug) do
    {_out, code} = System.cmd("launchctl", ["print", service(slug)], stderr_to_stdout: true)
    code == 0
  end

  def log_tail(slug, lines \\ 300) do
    case File.read(log_path(slug)) do
      {:ok, txt} -> txt |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")
      _ -> ""
    end
  end

  defp last_run(slug) do
    with {:ok, txt} <- File.read(result_path(slug)),
         {:ok, map} <- Jason.decode(txt) do
      map
    else
      _ -> nil
    end
  end

  # ── internals ─────────────────────────────────────────────
  defp validate(p) do
    name = String.trim(p["name"] || "")
    prompt = String.trim(p["prompt"] || "")
    command = String.trim(p["command"] || "")

    cond do
      name == "" ->
        {:error, "name is required"}

      prompt == "" and command == "" ->
        {:error, "a prompt (claude) or a command (shell) is required"}

      prompt != "" and command != "" ->
        {:error, "give either a prompt or a command, not both"}

      slugify(name) == "" ->
        {:error, "name must contain letters or numbers"}

      true ->
        run = if command != "", do: %{"command" => command}, else: %{"prompt" => prompt}

        with sched when is_map(sched) <- parse_schedule_string(p["schedule"]),
             do: {:ok, %{name: name, run: run, schedule: sched}}
    end
  end

  @doc """
  Parse a schedule string into a schedule map, or return `{:error, message}`:

      every 6h · every 30m · every 90s · every 1d          → interval (StartInterval)
      0 9 * * * · 0 9-17 * * 1-5 · */30 9-17 * * mon-fri    → cron (StartCalendarInterval)

  Anything not starting with `every` is treated as a 5-field cron expression
  (minute hour day-of-month month day-of-week).
  """
  def parse_schedule_string(str) do
    s = str |> to_string() |> String.trim() |> String.downcase()

    cond do
      s == "" -> {:error, "schedule is required"}
      String.starts_with?(s, "every") -> parse_every(s)
      true -> parse_cron(s)
    end
  end

  defp parse_every(s) do
    case Regex.run(~r/^every\s+(\d+)\s*([smhd])$/, s) do
      [_, n, u] when n != "0" ->
        %{"seconds" => String.to_integer(n) * @units[u], "type" => "interval"}

      _ ->
        {:error, "try: every 6h · every 30m · every 90s · every 1d"}
    end
  end

  # ── cron → launchd StartCalendarInterval ──────────────────
  # A standard 5-field cron expr (minute hour day-of-month month day-of-week) compiles
  # to launchd by expanding only the CONSTRAINED fields into the cartesian product of
  # `<dict>`s; `*` fields are omitted, which launchd reads as "every" — exactly cron's
  # semantics (`man launchd.plist`: "Missing arguments are considered to be wildcard").
  defp parse_cron(s) do
    case cron_intervals(s) do
      {:ok, _dicts} -> %{"expr" => s |> String.split() |> Enum.join(" "), "type" => "cron"}
      :error -> {:error, "cron: min hour day month weekday — e.g. 0 9 * * * · 0 9-17 * * 1-5"}
    end
  end

  @doc """
  Compile a 5-field cron expression into launchd `StartCalendarInterval` entries — a
  list of maps keyed by `"Minute"/"Hour"/"Day"/"Month"/"Weekday"` carrying only the
  constrained fields (wildcards omitted). Returns `{:ok, dicts}` or `:error`.
  """
  def cron_intervals(expr) do
    with [mn, hr, dom, mon, dow] <- String.split(expr),
         {:ok, minutes} <- cron_field(mn, 0, 59, %{}),
         {:ok, hours} <- cron_field(hr, 0, 23, %{}),
         {:ok, days} <- cron_field(dom, 1, 31, %{}),
         {:ok, months} <- cron_field(mon, 1, 12, @month_names),
         {:ok, weekdays} <- cron_field(dow, 0, 7, @dow_names) do
      constrained =
        [
          {"Minute", minutes},
          {"Hour", hours},
          {"Day", days},
          {"Month", months},
          {"Weekday", dedup_dow(weekdays)}
        ]
        |> Enum.reject(fn {_k, v} -> v == :wild end)

      count = constrained |> Enum.map(fn {_k, v} -> length(v) end) |> Enum.product()
      if count > @cron_max_dicts, do: :error, else: {:ok, cron_cartesian(constrained)}
    else
      _ -> :error
    end
  end

  # Sunday is 0; launchd also accepts 7 — fold 7→0 so it never emits a duplicate dict.
  defp dedup_dow(:wild), do: :wild

  defp dedup_dow(days),
    do: days |> Enum.map(&if(&1 == 7, do: 0, else: &1)) |> Enum.uniq() |> Enum.sort()

  defp cron_cartesian(fields) do
    Enum.reduce(fields, [%{}], fn {key, vals}, acc ->
      for combo <- acc, v <- vals, do: Map.put(combo, key, v)
    end)
  end

  # A comma-list of parts; a lone `*` part collapses the whole field to `:wild`.
  defp cron_field(spec, min, max, names) do
    spec
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case cron_part(part, min, max, names) do
        {:ok, :wild} -> {:halt, {:ok, :wild}}
        {:ok, vals} -> {:cont, {:ok, acc ++ vals}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, :wild} -> {:ok, :wild}
      {:ok, vals} -> {:ok, vals |> Enum.uniq() |> Enum.sort()}
      :error -> :error
    end
  end

  # One cron part: `*`, `a`, `a-b`, or any of those with a `/step` suffix.
  defp cron_part(part, min, max, names) do
    {base, step} =
      case String.split(part, "/") do
        [b] -> {b, 1}
        [b, s] -> {b, cron_int(s)}
        _ -> {:bad, :bad}
      end

    with true <- is_integer(step) and step >= 1,
         {:ok, lo, hi, wild?} <- cron_bounds(base, min, max, names) do
      cond do
        wild? and step == 1 ->
          {:ok, :wild}

        true ->
          # `*/n` and `a/n` step from the low bound to the field max; `a-b/n` respects b.
          upper = if step > 1 and (wild? or lo == hi), do: max, else: hi
          vals = lo |> Stream.iterate(&(&1 + step)) |> Enum.take_while(&(&1 <= upper))
          if vals == [], do: :error, else: {:ok, vals}
      end
    else
      _ -> :error
    end
  end

  defp cron_bounds("*", min, max, _names), do: {:ok, min, max, true}

  defp cron_bounds(base, min, max, names) do
    case String.split(base, "-") do
      [a] ->
        with {:ok, n} <- cron_name(a, names), true <- n in min..max, do: {:ok, n, n, false}

      [a, b] ->
        with {:ok, x} <- cron_name(a, names),
             {:ok, y} <- cron_name(b, names),
             true <- x in min..max and y in min..max and x <= y,
             do: {:ok, x, y, false}

      _ ->
        :error
    end
  end

  defp cron_name(tok, names) do
    case Map.fetch(names, tok) do
      {:ok, n} -> {:ok, n}
      :error -> with n when is_integer(n) <- cron_int(tok), do: {:ok, n}
    end
  end

  defp cron_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> :bad
    end
  end

  defp install_agent(r) do
    slug = r["slug"]
    File.mkdir_p!(routines_dir())
    if r["prompt"], do: File.write!(prompt_path(slug), r["prompt"])
    File.write!(script_path(slug), script_for(slug, r))
    File.chmod!(script_path(slug), 0o755)
    File.mkdir_p!(Path.dirname(plist_path(slug)))
    File.write!(plist_path(slug), plist_for(slug, r["schedule"]))
    if loaded?(slug), do: bootout(slug)
    System.cmd("launchctl", ["bootstrap", domain(), plist_path(slug)], stderr_to_stdout: true)
  end

  defp bootout(slug),
    do: System.cmd("launchctl", ["bootout", service(slug)], stderr_to_stdout: true)

  defp read_routines do
    case File.read(routines_file()) do
      {:error, :enoent} ->
        default_routines()

      {:ok, txt} ->
        case Jason.decode(txt) do
          {:ok, list} when is_list(list) ->
            list

          # File exists but won't parse (torn/corrupt write). Do NOT fall back to
          # defaults — that would make the next create/update/delete persist
          # defaults-plus-edit and permanently erase the real routines. Fail loud.
          _ ->
            raise "routines.json is unreadable — refusing to overwrite it with defaults"
        end

      {:error, reason} ->
        raise "cannot read routines.json: #{inspect(reason)}"
    end
  end

  defp write_routines(list) do
    Orrery.Store.write!(routines_file(), Jason.encode!(list, pretty: true))
  end

  defp slugify(name),
    do:
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)

  # ── paths ─────────────────────────────────────────────────
  defp home, do: System.user_home!()
  defp routines_dir, do: "/Users/jlg/GitHub/jgeschwendt/orrery/data/@routines"
  defp routines_file, do: Path.join(routines_dir(), "routines.json")
  defp result_path(slug), do: Path.join(routines_dir(), "#{slug}.last-run.json")
  defp prompt_path(slug), do: Path.join(routines_dir(), "#{slug}.prompt.txt")

  defp uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil ->
        uid = "id" |> System.cmd(["-u"]) |> elem(0) |> String.trim()
        :persistent_term.put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  end

  defp domain, do: "gui/#{uid()}"
  defp service(slug), do: "#{domain()}/#{label(slug)}"

  # ── generated files ───────────────────────────────────────
  # `$HOME`/`$START`/… are bash expansions (Elixir only interpolates `#\{}`); the
  # prompt is read from a sibling file via "$(cat …)" so arbitrary prompt text can
  # never break the script's quoting. JSON is written with a heredoc (no escapes).
  defp script_for(slug, r) do
    """
    #!/usr/bin/env bash
    set -uo pipefail
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

    DIR="#{routines_dir()}"
    START="$(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "──────── #{slug} · started $START ────────"

    #{run_line(slug, r)}
    CODE=$?

    END="$(date +%Y-%m-%dT%H:%M:%S%z)"
    cat > "$DIR/#{slug}.last-run.json" <<EOF
    {"started":"$START","finished":"$END","exit":$CODE}
    EOF
    echo "──────── done · exit $CODE · $END ────────"
    exit $CODE
    """
  end

  # Command routines run the shell line as-is; prompt routines run unattended claude.
  # --no-session-persistence: unattended runs shouldn't leave transcripts cluttering
  # the human's Conversations view (and the voyage log must not summarize its own run).
  defp run_line(_slug, %{"command" => command}) when is_binary(command), do: command

  defp run_line(slug, _r),
    do:
      ~s|claude --permission-mode=auto --no-session-persistence -p "$(cat "$DIR/#{slug}.prompt.txt")"|

  defp plist_for(slug, schedule) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{label(slug)}</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/bash</string>
        <string>#{script_path(slug)}</string>
      </array>
    #{schedule_plist(schedule)}  <key>RunAtLoad</key><false/>
      <key>ProcessType</key><string>Background</string>
      <key>StandardOutPath</key><string>#{log_path(slug)}</string>
      <key>StandardErrorPath</key><string>#{log_path(slug)}</string>
      <key>EnvironmentVariables</key>
      <dict>
        <key>HOME</key><string>#{home()}</string>
        <key>PATH</key><string>#{home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
      </dict>
    </dict>
    </plist>
    """
  end

  defp schedule_plist(%{"type" => "cron", "expr" => expr}) do
    {:ok, dicts} = cron_intervals(expr)

    "  <key>StartCalendarInterval</key>\n  <array>#{Enum.map_join(dicts, &interval_dict/1)}</array>\n"
  end

  defp schedule_plist(%{"type" => "interval", "seconds" => s}),
    do: "  <key>StartInterval</key><integer>#{s}</integer>\n"

  defp interval_dict(fields) do
    inner =
      for key <- ~w(Minute Hour Day Month Weekday), Map.has_key?(fields, key), into: "" do
        "<key>#{key}</key><integer>#{fields[key]}</integer>"
      end

    "<dict>#{inner}</dict>"
  end
end
