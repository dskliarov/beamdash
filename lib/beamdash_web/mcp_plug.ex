defmodule BeamdashWeb.McpPlug do
  @moduledoc """
  The MCP endpoint at `/mcp`: JSON-RPC 2.0 over HTTP POST, offering the
  tools of `Beamdash.Mcp`. Only loopback clients get in. The listener is
  bound to 127.0.0.1, and the client address, Host and Origin are checked
  as well, so a web page open in the browser cannot reach it (DNS rebinding).
  """

  @behaviour Plug

  import Plug.Conn

  alias Beamdash.Mcp

  @protocol_version "2025-06-18"
  @loopback_hosts ~w(localhost 127.0.0.1 ::1 [::1])

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not (loopback_client?(conn.remote_ip) and loopback_host?(conn.host) and origin_ok?(conn)) ->
        conn |> send_resp(403, "Forbidden") |> halt()

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> send_resp(405, "Method Not Allowed") |> halt()

      true ->
        handle(conn)
    end
  end

  defp handle(conn) do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "method" => method} = msg when is_binary(method) ->
        if Map.has_key?(msg, "id") do
          reply(conn, 200, rpc(method, msg["params"] || %{}, msg["id"]))
        else
          conn |> send_resp(202, "") |> halt()
        end

      _ ->
        reply(conn, 400, error(nil, -32600, "Invalid Request"))
    end
  end

  defp rpc("initialize", _params, id) do
    result(id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "beamdash", version: to_string(Application.spec(:beamdash, :vsn))}
    })
  end

  defp rpc("ping", _params, id), do: result(id, %{})
  defp rpc("tools/list", _params, id), do: result(id, %{tools: Mcp.tools()})

  defp rpc("tools/call", %{"arguments" => args}, id) when not is_map(args) and not is_nil(args),
    do: error(id, -32602, "arguments must be an object")

  defp rpc("tools/call", %{"name" => name} = params, id) when is_binary(name) do
    case Mcp.call(name, params["arguments"] || %{}) do
      {:ok, data} -> result(id, tool_result(Jason.encode!(data), false))
      {:error, message} -> result(id, tool_result(message, true))
      :unknown_tool -> error(id, -32602, "Unknown tool: #{name}")
    end
  end

  defp rpc("tools/call", _params, id), do: error(id, -32602, "tools/call needs a tool name")
  defp rpc(method, _params, id), do: error(id, -32601, "Method not found: #{method}")

  defp result(id, value), do: %{jsonrpc: "2.0", id: id, result: value}

  defp error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp tool_result(text, error?), do: %{content: [%{type: "text", text: text}], isError: error?}

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp loopback_client?({127, _, _, _}), do: true
  defp loopback_client?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_client?(_address), do: false

  defp loopback_host?(host) when is_binary(host), do: String.downcase(host) in @loopback_hosts
  defp loopback_host?(_host), do: false

  defp origin_ok?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> loopback_host?(URI.parse(origin).host)
      _ -> false
    end
  end
end
