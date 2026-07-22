# orrery

```stele
kind: system
purpose: Phoenix app behind ~/.claude — memory sweep pipeline, launchd routines, voyage log, dashboard LiveViews. Code lives here; all data lives under ~/.orrery and ~/.claude, never the repo tree.
commands:
  setup: mise exec -- mix setup
  server: mise exec -- mix phx.server
  test: mix test
  precommit: mix precommit
invariants:
  - claim: the endpoint binds loopback only, always — every route mutates ~/.claude with no authentication, so there is no bind override; LAN-facing intake belongs to the separate scratchpad app
    anchor: lm:loopback-bind
edges:
  depends: [lib]
```

<!-- stele:begin router -->

## Hazards (1 active)

- ⚠ `lib`: an inline onclick stopPropagation wrapper kills every nested phx-click (LiveView's listener is delegated) and no LiveViewTest can catch it — use phx-click-away instead (→ lm:click-away-drawer)

## Map

| node | kind      | purpose                                                                                                                                                                                                  | unfold                                         |
| ---- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| lib  | container | Orrery.* domain — memory banks + sweep pipeline, transcripts, voyage log, routines, watcher, file Store — and OrreryWeb.* dashboard LiveViews. No database; the filesystem under ~/.orrery is the store. | `stele unfold lib` · or read `lib/AGENTS.md`   |
| test | container | ExUnit suite. Any test touching data must repoint the :orrery roots (memory_root, log_root, projects_dir, …) at tmp dirs via Application.put_env — the suite never reads or writes the real ~/.orrery.   | `stele unfold test` · or read `test/AGENTS.md` |

## Indexes

All invariants: `.stele/index/invariants.md` · all hazards: `.stele/index/hazards.md`

## Engine

`stele` CLI available → `stele root | unfold <id> | invariants --touching <path> | hazards | nodes --kind <k>`. MCP: `stele serve`.
No engine → everything above is complete; nested AGENTS.md files carry the detail (nearest file wins).
<!-- stele:end -->
