defmodule BeamdashWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeamdashWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", BeamdashWeb do
    pipe_through :browser

    live_session :default,
      on_mount: [BeamdashWeb.Syntax, BeamdashWeb.Connection, BeamdashWeb.Ask] do
      live "/", HomeLive
      live "/system", SystemLive
      live "/load", LoadLive
      live "/apps", AppsLive
      live "/memory", MemoryLive
      live "/logs", LogsLive
      live "/gc", GCLive
      live "/trace", TraceLive
      live "/seq", SeqLive
      live "/profile", ProfileLive
      live "/crashes", CrashLive
      live "/settings", SettingsLive
    end
  end
end
