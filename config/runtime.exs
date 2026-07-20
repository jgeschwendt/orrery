import Config

# Executed for all environments at boot (after compilation), so it is the place
# for configuration read from the machine — env vars, secrets.

# Every route serves ~/.claude contents and mutates it (deletes transcripts,
# rewrites memory, schedules auto-approved `claude` runs) with NO authentication,
# so the endpoint binds loopback only, always — no override. LAN-facing intake
# (feedback, cross-machine agent chat) lives in the separate `scratchpad` app.
bind =
  if config_env() == :prod, do: {0, 0, 0, 0, 0, 0, 0, 1}, else: {127, 0, 0, 1}

config :orrery, OrreryWeb.Endpoint,
  http: [ip: bind, port: String.to_integer(System.get_env("PORT", "1024"))]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :orrery, OrreryWeb.Endpoint, secret_key_base: secret_key_base
end
