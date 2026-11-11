defmodule BeamdashWeb.ReportsPlug do
  @moduledoc """
  `POST /reports`: an AI agent publishes a triage report (see `Beamdash.Reports`).
  Only loopback clients get in, and each sends the token of its own report
  client as `Authorization: Bearer <token>`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Beamdash.{Reports, Target}
  alias BeamdashWeb.Loopback

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    server = Keyword.get(opts, :target, Target)

    cond do
      not Loopback.allowed?(conn) ->
        conn |> send_resp(403, "Forbidden") |> halt()

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> send_resp(405, "Method Not Allowed") |> halt()

      true ->
        authenticate(conn, server)
    end
  end

  defp authenticate(conn, server) do
    case conn |> bearer() |> Reports.authenticate() do
      {:ok, client} ->
        publish(conn, client, server)

      :error ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> reply(401, %{error: "a report token is needed"})
    end
  end

  defp publish(conn, client, server) do
    case Target.status(server) do
      %{status: :connected, node: node} ->
        case Reports.publish(client, conn.body_params, node) do
          {:ok, run_id, :stored} ->
            reply(conn, 201, %{run_id: run_id, status: "stored"})

          {:ok, run_id, :existing} ->
            reply(conn, 200, %{run_id: run_id, status: "already stored"})

          {:error, :store_down} ->
            reply(conn, 503, %{error: "the event store is not running"})

          {:error, message} ->
            reply(conn, 422, %{error: message})
        end

      _ ->
        reply(conn, 409, %{error: "beamdash is not connected to a node"})
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
