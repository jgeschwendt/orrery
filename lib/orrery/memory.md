# The Memory System

One bank per working directory under `~/.claude/@memory`. Sessions read their bank back at
birth, write memories the moment they surface, and are **enqueued whole at death** —
`/dissolve` appends the session to the dissolve queue and kills it in milliseconds; all
extraction happens later, server-side, in the hourly sweep. There is exactly ONE
extraction pipeline (extract → judge → commit, all through `Orrery.Memory` — the single
format authority) and no human review anywhere: verification is a judge pass, and the
dashboard is a viewer/editor with manual triggers, never a gate.

## System map

```mermaid
flowchart TB
    subgraph session["Live Claude Code session"]
        SS[session start]
        MID["durable fact surfaces mid-task<br/>(write at time of attention)"]
        DIS["/dissolve — enqueue + kill, instant"]
        DEL["/delete — kill only, no extraction<br/>(default archives; /delete hard erases outright)"]
    end

    HOOK["hooks/memory-recall.js (SessionStart)<br/>cwd bank + ancestor banks, ≤9k chars,<br/>recall:pin + user/feedback full-body first,<br/>degrade to index (pin stays full), recall:mute skipped"]
    HOOK -->|additionalContext| SS

    STG[".staging.json — the inbox<br/>(mid-session writes +<br/>judge-failure fallback)"]
    MID --> STG

    Q[".dissolve-queue.jsonl<br/>{id, cwd, title, queued_at}"]
    DIS -->|enqueue.sh| Q
    DIS -->|then invokes| DEL
    DEL -->|"archive + finalize<br/>(delete-session.sh; hard mode skips the archive,<br/>erases the .jsonl outright)"| ARC["@log/archive/&lt;date&gt;/&lt;sid&gt;.jsonl.gz<br/>(recoverable, un-resumable)"]

    subgraph pipeline["One pipeline: extract → judge → commit"]
        X[extract candidates]
        J{judge}
        C["commit_memory/1"]
        X --> J
        J -->|commit| C
        J -->|drop| DROP[discarded]
        J -->|judge unavailable| STG
    end

    subgraph sweep["launchd · hourly · mix memory.sweep"]
        SW["Sweep.run — queue first,<br/>then idle sessions"]
        DR["drain_inbox — judge staged entries"]
        CO["Dream.run_due — shrink grown banks"]
    end
    Q --> SW
    ARC -->|"parse_archived/1"| SW
    SW --> X
    STG --> DR --> J
    CO -->|"merge/rewrite/archive ops"| C

    subgraph web["orrery dashboard"]
        UI["MemoriesLive<br/>browse · edit · merge · restore ·<br/>dissolve picker · dream instructions ·<br/>sweep-now · dream-now"]
    end
    UI -->|"distill_session/2"| X
    UI -->|"merge_memories/2 (claude call,<br/>commits directly)"| C

    C --> BANK[("~/.claude/@memory/&lt;bank&gt;/<br/>&lt;type&gt;_&lt;slug&gt;.md · MEMORY.md ·<br/>_archive/ · _dream.json")]
    BANK --> HOOK
    UI --- BANK

    DREAM["_dream.md<br/>(else @default_dream)"] -.->|tunes extraction,<br/>judging & the dream| X
    DREAM -.-> J
    DREAM -.-> CO
    LEDGER[".sweep.jsonl — append-only ledger"] -.-> SW
```

Session end is deliberately dumb and fast: `/dissolve` = stage-anything-urgent + drain the
coding-standards queue + one queue append + `/delete`; `/delete` = archive + kill. No
claude call ever runs at session end. The sweep owns every extraction, so the skill-side
judge and `commit-memories.sh` mirror are gone — there is nothing left to drift.

## Life of a memory

```mermaid
stateDiagram-v2
    [*] --> Candidate: extracted by the sweep /<br/>staged at time of attention
    Candidate --> Committed: judge commit
    Candidate --> Dropped: judge drop<br/>(dup · derivable · ephemeral)
    Candidate --> Inbox: judge call failed —<br/>parked in .staging.json
    Inbox --> Candidate: hourly drain_inbox
    Inbox --> Dropped: dashboard discard /<br/>judge drop on drain
    Inbox --> Committed: dashboard commit-now<br/>(explicit, skips the judge)
    Committed --> Archived: superseded via replaces ·<br/>delete_memory · dream archive-op
    Archived --> Committed: restore_memory/2<br/>(dashboard Archive panel)
    Archived --> [*]: _archive/&lt;stamp&gt;_&lt;file&gt;<br/>(kept forever otherwise)
    note right of Committed
        bi-temporal: created inherited from the
        oldest replaced file, updated = this rewrite;
        MEMORY.md regenerated on every mutation
    end note
```

Judge bars (`Orrery.Memory.judge/2`, read under the dream — the same curation guidance the
extractor followed): **durable** (useful in a future, unrelated session) · **non-derivable**
(not recoverable from code/git/CLAUDE.md) · **one idea per memory** · **description specific
enough to trigger recall**. Dedup runs against the existing memories' **full bodies** (not
titles) as a cascade, most decisive rule first: covered by an existing body → drop;
updates/corrects/subsumes → commit with those files in `replaces`; contradicts an existing
memory → the candidate is the newer observation, commit with the contradicted file in
`replaces`; otherwise genuinely new → commit. Tie-break: _when in doubt, drop_ — with no
reviewer downstream, a missed memory costs less than committed noise.

## Banks and memory files

Bank id = cwd with every non-alphanumeric character replaced by `-` (`sanitize/1`):
`/Users/jlg/GitHub/jgeschwendt/grove` → `-Users-jlg-GitHub-jgeschwendt-grove`.

```
~/.claude/@memory/
├── .dissolve-queue.jsonl             # sessions awaiting extraction (append-only producers)
├── .staging.json                     # inbox / fallback queue (array of memory maps)
├── .sweep.jsonl                      # append-only sweep ledger (newest line per session wins)
├── _dream.md                         # optional curation guidance (else @default_dream)
└── <bank>/
    ├── MEMORY.md                     # regenerated index — never hand-edited, ≤180 entries
    ├── <type>_<slug>.md              # one memory per file
    ├── _archive/<stamp>_<file>       # superseded/deleted memories — recoverable, restorable
    └── _dream.json                   # dream state {at, count, last_ops} (legacy fallback: _consolidation.json)
```

Underscore- and dot-prefixed entries are invisible to `read_dir/4` — archives and state
files never re-enter listings or the index.

Memory file serialization (`serialize_memory/1`):

```markdown
---
name: <human-readable title, ≤90 chars>
description: <one-line recall summary, whitespace collapsed>
type: feedback | project | reference | user
created: <ISO8601 — when the fact first became known; survives rewrites>
recall: <optional — pin | index | mute; absent = the recall hook's type policy>
source: <session uuid — omitted if unknown>
updated: <ISO8601 — this rewrite>
---

<body — for feedback/project: the rule, then **Why:**, then **How to apply:**>
```

## `commit_memory/1` — the single format authority

```mermaid
flowchart TD
    IN["memory {bank, name, description, type, body, replaces, source}"]
    IN --> W{"writable?<br/>not auto:* · safe path component"}
    W -->|no| REJ[":not_writable"]
    W --> R["filter replaces to safe bank-local filenames"]
    R --> CR["inherit created = oldest created<br/>among replaced files (lineage)"]
    CR --> AR["archive each replaced file →<br/>_archive/&lt;UTC stamp&gt;_&lt;file&gt;"]
    AR --> FN["filename: &lt;type&gt;_&lt;slug&gt;.md<br/>slug: downcase, [^a-z0-9]+→_, ≤60;<br/>empty slug → x+sha1[0..8]"]
    FN --> COL{"target exists with a<br/>different memory inside?"}
    COL -->|yes| SUF["suffix _2, _3, … — never clobber"]
    COL -->|no| WR
    SUF --> WR["Store.write! (atomic temp+rename)"]
    WR --> PR["prune same bank+name from .staging.json"]
    PR --> IX["regen MEMORY.md — sorted, ≤180 entries,<br/>overflow line: '…N more memories not indexed — dream this bank'"]
```

## The write paths

| Path                  | Extractor                            | Judge                          | Committer                  |
| --------------------- | ------------------------------------ | ------------------------------ | -------------------------- |
| `/dissolve` (skill)   | none — enqueues for the sweep        | —                              | —                          |
| sweep · queue entries | `claude -p` over archived transcript | 2nd `claude -p`                | `commit_memory/1`          |
| sweep · idle sessions | `claude -p` over live transcript     | same                           | same                       |
| dashboard dissolve    | same (`distill_session/2`)           | same                           | same                       |
| mid-session staging   | the live session (time of attention) | `drain_inbox` on next sweep    | same                       |
| dashboard merge       | `claude -p` merge prompt             | none — the click is the review | same, `replaces` = sources |
| dream (consolidation) | `claude -p` over the whole bank      | op validation (`valid_op?/2`)  | same / `delete_memory/2`   |

### Session end — `/dissolve` and `/delete`

```mermaid
sequenceDiagram
    participant S as dying session
    participant Q as .dissolve-queue.jsonl
    participant D as delete-session.sh
    participant A as @log/archive

    S->>S: stage anything the NEXT session needs<br/>(usually already staged at time of attention)
    S->>Q: enqueue.sh — append {id, cwd, title, queued_at}
    S->>D: invoke /delete (canonical kill)
    D->>A: gzip-copy NOW (--now), mark archive-on-exit
    D->>S: Ctrl-C ×2 → SIGTERM
    Note over D,A: post-exit finalize re-archives the final flush,<br/>removes the live .jsonl — un-resumable
```

`/delete` alone is the same minus the enqueue — the session had no value, no extraction is
spent on it. Recovering a queued-but-unwanted session: remove its line from the queue;
resuming an archived one: gunzip the archive back into `~/.claude/projects/<project>/`.
`/delete hard` skips the archive step entirely and erases the live `.jsonl` outright — nothing
to recover, and `/dissolve` never uses it (the archive is what the sweep reads).
(since 2026-07-19 · /delete hard)

## The hourly sweep

```mermaid
flowchart TD
    L["launchd · com.claude.routines.memory-sweep<br/>interval 3600s"] --> MX["mix memory.sweep<br/>(no supervision tree — safe beside a dev server)"]
    UI2["dashboard 'Sweep now'"] --> RUN
    MX --> RUN["Sweep.run(max: 3)"]

    RUN --> IB["drain_inbox: group .staging.json by bank →<br/>judge each group → commit survivors, drop losers;<br/>judge failure = keep for next run"]

    RUN --> QC["consume queue FIRST — explicit user intent,<br/>counts against the same max"]
    QC --> QA{"parse_archived(id)?"}
    QA -->|"no archive, entry < 24h"| QW["waiting — stays queued, no ledger spam"]
    QA -->|"no archive, entry ≥ 24h"| QL["ledger: lost — consumed"]
    QA -->|"< 4 messages"| QT["ledger: trivial — consumed"]
    QA -->|parsed| QD["distill from archive"]
    QD -->|error| QE["ledger: error — stays queued, retries"]
    QD -->|ok| QOK["ledger: dissolved/staged — consumed"]

    RUN --> LS["Transcripts.list_sessions (live)"]
    LS --> SQ{"sweepable?"}
    SQ -->|"idle < 48h"| NO1[skip — may still be resumed]
    SQ -->|"@log/.archive-on-exit marker"| NO2[skip — session-end machinery owns it]
    SQ -->|"ledger: dissolved/staged"| NO3[skip forever]
    SQ -->|"ledger: trivial, unchanged"| NO4["skip — re-arms if messages grew"]
    SQ -->|yes| MC{"≥ 4 messages?"}
    MC -->|no| TRIV["ledger: trivial — transcript untouched"]
    MC -->|yes| CAP{"cap left after queue?"}
    CAP -->|no| DEF[deferred to next hour]
    CAP -->|yes| D2["distill_session → consume transcript<br/>(only extraction error keeps it)"]

    RUN --> CD["Dream.run_due"]
```

Idle-session contract: the transcript is consumed on **any successful extraction** —
including a clean zero and `staged` (candidates safe in the inbox). Only an extraction
_error_ preserves it. Quiescence replaces session-end hooks deliberately: hooks are
disabled in some sessions, and an end event can't shorten the idle wait anyway.

### One extraction call — `Orrery.Claude`

Every server-side claude call is `claude -p --output-format json --no-session-persistence
--setting-sources '' --disable-slash-commands --model sonnet --json-schema …` with
`CLAUDE_MEMORY_PIPELINE=1` exported — the recall hook exits and the SessionEnd hook
refuses under that flag, so pipeline runs can never feed the pipeline their own children,
and extraction is never biased by existing memories. Long conversations are flattened
(tool calls one-lined, subagent sidechains dropped) and capped at 60k chars (head +
tail kept, middle truncated).

## The dream (sleep-time consolidation)

Not the _voyage log_ (the page-per-day distiller that turns archived transcripts
into voyage-log pages) — this is the sleep-time pass that merges, rewrites, and archives to keep
a grown bank sharp.

```mermaid
flowchart TD
    RD["Dream.run_due — every managed bank dir"] --> BASE{"_dream.json exists?"}
    UI3["dashboard 'dream' button<br/>(bypasses due-ness)"] --> CALL
    BASE -->|no| SEED["write baseline {at, count} — never<br/>mass-dream a backlog on first sight"]
    BASE -->|yes| DUE{"grown ≥5 memories since last pass<br/>AND ≥20h since last pass?"}
    DUE -->|no| WAIT[skip]
    DUE -->|yes| CALL["ONE claude call: whole bank in,<br/>≤6 ops out — net-non-increasing"]
    CALL --> V{"valid_op? files really exist in bank;<br/>merge needs ≥2 files + memory,<br/>rewrite exactly 1 + memory"}
    V -->|merge| CM["commit_memory with replaces=files<br/>→ lineage, archive, index — all inherited"]
    V -->|rewrite| CM
    V -->|archive| DL["delete_memory → _archive/"]
    CM --> ST["write state {at, count, last_ops}"]
    DL --> ST
```

## Recall (read path)

```mermaid
flowchart LR
    START[SessionStart] --> ENV{"CLAUDE_MEMORY_PIPELINE=1?"}
    ENV -->|yes| BLIND["exit 0 — pipeline runs stay memory-blind"]
    ENV -->|no| CHAIN["walk cwd → ancestors → $HOME,<br/>match banks case-insensitively"]
    CHAIN --> RANK["per bank: drop recall:mute, then sort<br/>recall:pin → user → feedback → project →<br/>reference, newest first within a rank"]
    RANK --> BUDGET{"render ≤ 9,000 chars?"}
    BUDGET -->|no| DEG["degrade farthest ancestor first:<br/>full bodies → index lines<br/>(recall:pin stays full)"]
    DEG --> BUDGET
    BUDGET -->|yes| INJ["additionalContext injection"]
    FALL["hooks disabled (work account):<br/>CLAUDE.md § Memory — read MEMORY.md manually"] -.-> INJ
```

An optional `recall:` frontmatter key lets a single memory override the hook's type-based
render policy (`hooks/memory-recall.js`); absent, or any value outside the trio, falls back
to that policy:

- **`pin`** — always rendered full-body regardless of type, and sorted **first** (ahead of
  even `user`). It stays a full `### ` block even when its bank degrades to index mode, so
  the degraded bank emits the pinned memory's full body above its index lines.
- **`index`** — always rendered as a one-line index entry regardless of type (even
  `user`/`feedback`, which the type policy would otherwise render full).
- **`mute`** — skipped entirely: it never appears in full mode nor as an index line.

Recall latency note: a dissolved session's memories exist only after the next sweep run
(≤1 h). Anything the very next session must know is covered by write-at-attention staging
— that file is read by nothing but the pipeline, and commits drain it.

## Staging — an inbox, not a review queue

`.staging.json` has exactly two legitimate populations:

1. **Inbox** — memories written at the time of attention by live sessions (cheap, no
   ceremony mid-task). The hourly `drain_inbox` runs them through the judge, whatever
   bank they target.
2. **Fallback** — a server-side dissolve whose judge call failed parks its candidates
   here instead of losing them.

The dashboard shows staged entries with commit-now / discard buttons as an escape hatch to
_preempt_ the sweep — commit-now explicitly skips the judge. Entry shape mirrors
`read_staging/0`: `{bank, body, description, name, recall, replaces, source, type}` (recall
optional — `pin | index | mute`); malformed
entries (no name/bank) are dropped rather than allowed to crash a later commit. Banks that
exist only in staging still surface in listings.

## Bank kinds

| Kind    | Source                                                           | Writable            |
| ------- | ---------------------------------------------------------------- | ------------------- |
| managed | `~/.claude/@memory/<bank>/` — this system                        | yes (`writable?/1`) |
| `auto:` | Claude Code's own `projects/*/memory/` dirs                      | read-only           |
| seeded  | `skills/sandman/memories` corpus, copied once (`.seeded` marker) | as managed          |

Banks whose name starts with `_` or `.` are never targeted. `writable?/1` also rejects any
bank id that isn't a safe path segment, so a tampered request (`bank: "../.."`) can't
escape the memory root.

## The dashboard's role

MemoriesLive is a **viewer/editor with manual triggers** — never an approval step:

- browse banks (managed + read-only auto), live-reloading via `Orrery.Watcher` PubSub
- pipeline panel: pending dissolve-queue entries + the recent sweep ledger
- edit/save any memory (a save is a `commit_memory` with `replaces` = the original file)
- merge N selected memories (one claude call, commits directly, sources archived)
- dream the active bank on demand; run the whole sweep on demand
- dissolve any conversation from the picker — sessions active within the last hour are
  flagged and confirm first; sessions pre-marked archive-on-exit are excluded outright
- Archive panel per bank: browse `_archive/`, restore any entry
  (`restore_memory/2` — re-commit, then the archive entry is consumed)
- dream editor (`_dream.md` — the curation guidance every extraction follows)

## Retention

```mermaid
flowchart LR
    T["projects/&lt;proj&gt;/&lt;sid&gt;.jsonl<br/>(live transcript)"] -->|"/dissolve · /delete (default) ·<br/>dashboard dissolve · hourly sweep"| G["@log/archive/&lt;date&gt;/&lt;sid&gt;.jsonl.gz"]
    T -->|"/delete hard — explicit erase"| ERASED["∅ erased outright<br/>(no archive, unrecoverable)"]
    G --> DRM["voyage log (fuel)"]
    G --> QX["dissolve-queue extraction<br/>(parse_archived/1)"]
    G -.->|"gunzip back into projects/<br/>restores resumability"| T
    M1["committed memory"] -->|superseded / deleted /<br/>dream-archived| A["&lt;bank&gt;/_archive/&lt;stamp&gt;_&lt;file&gt;"]
    A -->|"restore (dashboard)"| M1
```

Memories are the durable residue; transcripts are compact-deleted (gzip-archived,
recoverable, un-resumable in place). The one exception is `/delete hard` — an explicit-intent
erase that removes the transcript outright, no archive copy, unrecoverable, and never feeds the
voyage log. (since 2026-07-19 · /delete hard)
