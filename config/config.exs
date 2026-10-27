import Config

# Bound to localhost only: the UI can connect to any node whose cookie
# you type in, so it must not be reachable from the network.
config :beamdash, BeamdashWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [formats: [html: BeamdashWeb.ErrorHTML], layout: false],
  pubsub_server: Beamdash.PubSub,
  live_view: [signing_salt: "beamdash-lv"],
  # Only pages served from this machine may open the live socket, whichever
  # loopback name the browser used. This keeps other websites from driving
  # your nodes through beamdash.
  check_origin: ["//localhost", "//127.0.0.1", "//[::1]"],
  server: true

config :phoenix, :json_library, Jason

# Jev analysis (TypeSafe). `enabled: false` here, or JEV_ENABLED=false in the
# environment, turns it off entirely: no requests and nothing of it in the UI.
# The API key normally comes from TYPESAFE_API_KEY (config/runtime.exs).
config :beamdash, Beamdash.Jev,
  enabled: true,
  model: "jev-1.13.0"

if config_env() == :test do
  config :beamdash, BeamdashWeb.Endpoint, server: false
  config :logger, level: :warning

  # Set here, not in test_helper.exs: Beamdash.Plugins loads the plugins
  # when the app starts, before the helper runs. Removed after the suite.
  config :beamdash,
         :plugins_dir,
         Path.join(System.tmp_dir!(), "beamdash_test_plugins_#{System.pid()}")
end
