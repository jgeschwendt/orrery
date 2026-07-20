# orrery

The clockwork behind `~/.claude`. A Phoenix app that runs the memory sweep pipeline, the launchd routines, and the user log, and serves a set of dashboard LiveViews over them.

## What it does

- **Memory sweep** (`mix memory.sweep`) — dissolves idle sessions, drains the staging inbox, judges and commits durable memories into per-directory banks, and runs the dream (bank consolidation). Entry point for the hourly launchd routine.
- **Routines** — reads and schedules the launchd cron routines under `@routines`, with their scripts, prompts, and last-run results.
- **User log** — the day-by-day voyage/notes log under `@log`, mirroring the memory pipeline's per-day habit.
- **Dashboard LiveViews** — `/` conversations (transcripts), `/log` user log, `/memories` memory banks (view/edit/dissolve/delete), `/routines` launchd routines.

## Data contract

The code lives in this repo; all data it reads and mutates stays under `~/.claude`. Nothing durable is stored in the repo tree.

| Key | Default location | Override |
| --- | --- | --- |
| memory banks | `~/.claude/@memory` | `config :orrery, :memory_root` |
| user log | `~/.claude/@log` | `config :orrery, :log_root` |
| transcripts | `~/.claude/projects` | `config :orrery, :projects_dir` |
| routines | `~/.claude/@routines` | — |

Roots resolve against `System.user_home!()` at runtime, so the app follows whichever home it runs under. Each key above is overridable via `Application.get_env(:orrery, ...)` (routines is fixed) — the tests point the roots at fixtures this way.

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

**Loopback only, no override.** Every route serves and mutates `~/.claude` (deletes transcripts, rewrites memory, schedules auto-approved `claude` runs) with **no authentication**, so the endpoint never binds anything but loopback. LAN-facing intake (feedback, cross-machine agent chat) lives in the separate `scratchpad` app, which is deliberately open by design.

## Hourly sweep

A launchd routine (`~/.claude/@routines/memory-sweep.sh`) `cd`s into this repo and runs `mix memory.sweep` once an hour. The task runs without starting the web supervision tree (no endpoint, no port bind), so it is safe alongside a running dev server.

## Gate

```
mise exec -- mix precommit
```

Compiles with warnings-as-errors, checks for unused deps, formats, and runs the test suite. Run it before every commit.
