# Invariants

| claim | node | anchor |
| --- | --- | --- |
| the endpoint binds loopback only, always — every route mutates ~/.claude with no authentication, so there is no bind override; LAN-facing intake belongs to the separate scratchpad app | / | lm:loopback-bind |
| memories are never destroyed — supersede and delete both move the file to the bank's _archive/, so every autonomous rewrite stays recoverable | lib | lm:archive-on-delete |
| every data root resolves through Application.get_env(:orrery, …) with a ~/.orrery default — tests repoint roots at tmp dirs through that seam, nothing reaches past it | lib | lm:memory-root |
