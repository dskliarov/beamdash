defmodule BeamdashWeb.PluginAssetController do
  @moduledoc """
  Serves an installed plugin's stylesheet, `priv/static/plugin.css` in its
  source, at `/plugins/<app>/plugin.css`. Only an installed plugin's app is
  looked up, so no other file can be reached; anything else is a 404.
  """
  use Phoenix.Controller, formats: []
  import Plug.Conn

  def css(conn, %{"plugin" => app}) do
    # tests pass their own Beamdash.Plugins server
    server = conn.private[:beamdash_plugins_server] || Beamdash.Plugins

    case Beamdash.Plugins.css_path(server, app) do
      {:ok, path} ->
        conn
        |> put_resp_content_type("text/css")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_file(200, path)

      :error ->
        send_resp(conn, 404, "Not found")
    end
  end
end
