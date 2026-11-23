defmodule BeamdashWeb.ConnectionController do
  @moduledoc """
  Stores which connected node this browser session shows (see
  `BeamdashWeb.Connection`), then goes back to the page it came from. A
  LiveView cannot write the session cookie, so the connection bar's node
  selector links here.
  """
  use Phoenix.Controller, formats: []

  def select(conn, %{"node" => node} = params) do
    conn
    |> put_session("selected_node", String.slice(node, 0, 255))
    |> redirect(to: local_path(params["return_to"] || referer_path(conn)))
  end

  defp referer_path(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{path: path, query: query} when is_binary(path) <- URI.parse(referer) do
      if query, do: path <> "?" <> query, else: path
    else
      _ -> "/"
    end
  end

  defp local_path("/" <> rest = path) do
    if String.starts_with?(rest, "/") or String.contains?(path, "\\"), do: "/", else: path
  end

  defp local_path(_), do: "/"
end
