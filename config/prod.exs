import Config

config :orrery, OrreryWeb.Endpoint,
  url: [host: "localhost"],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info

# Runtime production configuration lives in config/runtime.exs.
