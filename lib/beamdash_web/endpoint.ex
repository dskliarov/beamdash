defmodule BeamdashWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :beamdash

  @session_options [
    store: :cookie,
    key: "_beamdash_key",
    signing_salt: "beamdash-session",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/assets", from: {:beamdash, "priv/static/assets"}, gzip: false
  plug Plug.Static, at: "/deps/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.js)

  plug Plug.Static,
    at: "/deps/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.js)

  plug Plug.RequestId

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BeamdashWeb.Router
end
