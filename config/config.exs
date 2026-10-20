import Config

# Bound to localhost only: the UI can connect to any node whose cookie
# you type in, so it must not be reachable from the network.
config :exberly, ExberlyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [formats: [html: ExberlyWeb.ErrorHTML], layout: false],
  pubsub_server: Exberly.PubSub,
  live_view: [signing_salt: "exberly-lv"],
  # Only pages served from this machine may open the live socket, whichever
  # loopback name the browser used. This keeps other websites from driving
  # your nodes through exberly.
  check_origin: ["//localhost", "//127.0.0.1", "//[::1]"],
  server: true

config :phoenix, :json_library, Jason

# Jev analysis (TypeSafe). `enabled: false` here, or JEV_ENABLED=false in the
# environment, turns it off entirely: no requests and nothing of it in the UI.
# The API key normally comes from TYPESAFE_API_KEY (config/runtime.exs).
config :exberly, Exberly.Jev,
  enabled: true,
  model: "jev-1.13.0"

if config_env() == :test do
  config :exberly, ExberlyWeb.Endpoint, server: false
  config :logger, level: :warning
end
