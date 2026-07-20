import Config

config :orrery, OrreryWeb.Endpoint,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "RfSxHoe8KymjpCCpNTPWw8m0I7ReTzCGX3iuYwSu/bPIyCKIERPW70qBiGzkgNPU",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:orrery, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:orrery, ~w(--watch)]}
  ]

# Reload browser tabs when matching files change.
config :orrery, OrreryWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"lib/orrery_web/router\.ex$"E,
      ~r"lib/orrery_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

# Enable dev routes (LiveDashboard at /dev/dashboard)
config :orrery, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix, :stacktrace_depth, 20

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
