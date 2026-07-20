# orrery

The clockwork behind `~/.claude`. A Phoenix app that runs the memory sweep pipeline, the launchd routines, and the user log, and serves a set of dashboard LiveViews over them.

## What it does

- **Memory sweep** (`mix memory.sweep`) — dissolves idle sessions, drains the staging inbox, judges and commits durable memories into per-directory banks, and runs the dream (bank consolidation). Entry point for the hourly launchd routine.
- **Routines** — reads and schedules the launchd cron routines under `@routines`, with their scripts, prompts, and last-run results.
- **User log** — the day-by-day voyage/notes log under `@log`, mirroring the memory pipeline's per-day habit.
- **Dashboard LiveViews** — `/` conversations (transcripts), `/log` user log, `/memories` memory banks (view/edit/dissolve/delete), `/routines` launchd routines. `POST /feedback` accepts flags from other machines/agents.

## Data contract

The code lives in this repo; all data it reads and mutates stays under `~/.claude`. Nothing durable is stored in the repo tree.

| Key | Default location | Override |
| --- | --- | --- |
| memory banks | `~/.claude/@memory` | `config :orrery, :memory_root` |
| user log | `~/.claude/@log` | `config :orrery, :log_root` |
| transcripts | `~/.claude/projects` | `config :orrery, :projects_dir` |
| feedback inbox | `~/.claude/@feedback` | `config :orrery, :feedback_root` |
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

Serves at http://127.0.0.1:1024. The default port is **1024**, not 4000; `PORT` overrides it. The bind interface defaults to loopback (`127.0.0.1`); `BIND` (an IP string, e.g. `BIND=0.0.0.0`) overrides it.

**Dev-bind caveat.** The endpoint binds `127.0.0.1` (loopback only) by default. Binding to the LAN is opt-in via `BIND`:

```
BIND=0.0.0.0 mise exec -- mix phx.server
```

This is needed so other machines on the LAN can `POST /feedback`, but it exposes **every** route — which serves and mutates `~/.claude` (deletes transcripts, rewrites memory, schedules auto-approved `claude` runs) with **no authentication**. LAN exposure is a deliberate, temporary security decision; drop the `BIND` override the moment LAN feedback isn't needed.

## Hourly sweep

A launchd routine (`~/.claude/@routines/memory-sweep.sh`) `cd`s into this repo and runs `mix memory.sweep` once an hour. The task runs without starting the web supervision tree (no endpoint, no port bind), so it is safe alongside a running dev server.

## Gate

```
mise exec -- mix precommit
```

Compiles with warnings-as-errors, checks for unused deps, formats, and runs the test suite. Run it before every commit.
