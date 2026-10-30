import Config

# A fresh secret per boot is fine for a local tool (sessions just reset).
config :beamdash, BeamdashWeb.Endpoint,
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48)),
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))]

# Optional Jev analysis (TypeSafe). Credentials stay on the beamdash host.
# Only variables that are set override config/config.exs, so `enabled: false`
# there keeps Jev off. The model is pinned; set TYPESAFE_MODEL to try another
# (re-run `mix beamdash.jev_eval` before switching).
jev_env =
  [
    # JEV_ENABLED=false turns Jev off entirely: no requests, nothing of it in the UI
    enabled:
      case System.get_env("JEV_ENABLED") do
        nil -> nil
        value -> String.downcase(String.trim(value)) not in ~w(false 0 no off)
      end,
    api_key: System.get_env("TYPESAFE_API_KEY"),
    model: System.get_env("TYPESAFE_MODEL"),
    cacertfile: System.get_env("TYPESAFE_CACERTFILE"),
    # only to test against a stand-in; default https://api.typesafe.ai/v1/systemone
    endpoint: System.get_env("TYPESAFE_ENDPOINT"),
    # Kev (self-hosted, same API): KEV_URL turns it on; its key goes only to it
    kev_url: System.get_env("KEV_URL"),
    # without KEV_URL: a Kev server on this machine at this port
    kev_port: System.get_env("KEV_PORT"),
    kev_api_key: System.get_env("KEV_API_KEY"),
    kev_model: System.get_env("KEV_MODEL"),
    kev_timeout: System.get_env("KEV_TIMEOUT"),
    # beamdash's own model (Nx), run locally: true turns it on
    nx: System.get_env("NX_MODEL"),
    # jev, kev or nx, when several are configured and none is chosen in Settings
    backend: System.get_env("DECISION_BACKEND")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if jev_env != [], do: config(:beamdash, Beamdash.Jev, jev_env)
