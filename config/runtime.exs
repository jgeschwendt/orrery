import Config

# Executed for all environments at boot (after compilation), so it is the place
# for configuration read from the machine — env vars, secrets.

# Interface bind is opt-in and defaults to loopback. Every route serves ~/.claude
# contents and mutates it (deletes transcripts, rewrites memory, schedules
# auto-approved `claude` runs) with NO authentication, so the default is loopback:
# {127, 0, 0, 1} in dev, {0, 0, 0, 0, 0, 0, 0, 1} (IPv6 loopback) in prod. Setting
# BIND=0.0.0.0 exposes every route to the entire LAN unauthenticated — a deliberate,
# temporary decision (e.g. to let another machine POST /feedback), not a default.
bind =
  case System.get_env("BIND") do
    nil ->
      if config_env() == :prod, do: {0, 0, 0, 0, 0, 0, 0, 1}, else: {127, 0, 0, 1}

    addr ->
      case :inet.parse_address(String.to_charlist(addr)) do
        {:ok, ip} -> ip
        {:error, _} -> raise "BIND=#{addr} is not a valid IP address"
      end
  end

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
