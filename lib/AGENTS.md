# lib

```stele
kind: container
purpose: Orrery.* domain — memory banks + sweep pipeline, transcripts, voyage log, routines, watcher, file Store — and OrreryWeb.* dashboard LiveViews. No database; the filesystem under ~/.orrery is the store.
commands:
  test: mix test
invariants:
  - claim: every data root resolves through Application.get_env(:orrery, …) with a ~/.orrery default — tests repoint roots at tmp dirs through that seam, nothing reaches past it
    anchor: lm:memory-root
  - claim: memories are never destroyed — supersede and delete both move the file to the bank's _archive/, so every autonomous rewrite stays recoverable
    anchor: lm:archive-on-delete
hazards:
  - claim: an inline onclick stopPropagation wrapper kills every nested phx-click (LiveView's listener is delegated) and no LiveViewTest can catch it — use phx-click-away instead
    anchor: lm:click-away-drawer
```

<!-- stele:begin router -->
<!-- stele:end -->
