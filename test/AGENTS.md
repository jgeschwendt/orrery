# test

```stele
kind: container
purpose: ExUnit suite. Any test touching data must repoint the :orrery roots (memory_root, log_root, projects_dir, …) at tmp dirs via Application.put_env — the suite never reads or writes the real ~/.orrery.
commands:
  test: mix test
  failed: mix test --failed
edges:
  depends: [lib]
```

<!-- stele:begin router -->
<!-- stele:end -->
