# orrery

The clockwork behind Claude Code on this machine. Its data substrate lives under `~/.orrery`; it reads and mutates Claude Code's transcripts in place under `~/.claude/projects`. A Phoenix app that runs the memory sweep pipeline, the launchd routines, and the user log, and serves a set of dashboard LiveViews over them.

## What it does

- **Memory sweep** (`mix memory.sweep`) — dissolves idle sessions, drains the staging inbox, judges and commits durable memories into per-directory banks, and runs the dream (bank consolidation). Entry point for the hourly launchd routine.
- **Routines** — reads and schedules the launchd cron routines under `~/.orrery/routines`, with their scripts, prompts, and last-run results.
- **User log** — the day-by-day voyage/notes log under `~/.orrery/log`, mirroring the memory pipeline's per-day habit.
- **Dashboard LiveViews** — `/` conversations (transcripts), `/log` user log, `/memories` memory banks (view/edit/dissolve/delete), `/routines` launchd routines.

## Data contract

The code lives in this repo; the data it reads and mutates stays under `~/.orrery`. The exception is transcripts, which it reads (and deletes) in place under `~/.claude/projects` — Claude Code's own directory. Nothing durable is stored in the repo tree.

| Key | Default location | Override |
| --- | --- | --- |
| memory banks | `~/.orrery/memory` | `config :orrery, :memory_root` |
| user log | `~/.orrery/log` | `config :orrery, :log_root` |
| transcript archive | `~/.orrery/archive` | `config :orrery, :archive_root` |
| transcripts | `~/.claude/projects` | `config :orrery, :projects_dir` |
| routines | `~/.orrery/routines` | `config :orrery, :routines_dir` |

Every default resolves against `System.user_home!()` at runtime — no hardcoded home paths — and every key is overridable via `Application.get_env(:orrery, ...)`; the tests point the roots at fixtures this way.

## Setup

```
mise install
mise exec -- mix setup
```

## Run

```
mise exec -- mix phx.server
```

Serves at http://127.0.0.1:1024. The default port is **1024**, not 4000; `PORT` overrides it. The bind interface is loopback only, always — `127.0.0.1` in dev, `::1` in prod — with no override.

**Loopback only, no override.** Every route serves and mutates `~/.orrery` (rewrites memory, schedules auto-approved `claude` runs) and deletes transcripts under `~/.claude/projects` with **no authentication**, so the endpoint never binds anything but loopback. LAN-facing intake (feedback, cross-machine agent chat) lives in the separate `scratchpad` app, which is deliberately open by design.

## Hourly sweep

A launchd routine (`~/.orrery/routines/memory-sweep.sh`) `cd`s into this repo and runs `mix memory.sweep` once an hour. The task runs without starting the web supervision tree (no endpoint, no port bind), so it is safe alongside a running dev server.

## Gate

```
mise exec -- mix precommit
```

Compiles with warnings-as-errors, checks for unused deps, formats, runs the test suite, and runs the stele graph checks (`stele check` + `stele emit --check`). Run it before every commit.
