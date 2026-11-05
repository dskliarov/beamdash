defmodule BeamdashWeb.McpPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias BeamdashWeb.McpPlug

  defp post(msg, opts \\ []) do
    conn(:post, "/mcp", Jason.encode!(msg))
    |> put_req_header("content-type", "application/json")
    |> Map.merge(%{
      host: Keyword.get(opts, :host, "localhost"),
      remote_ip: Keyword.get(opts, :ip, {127, 0, 0, 1})
    })
    |> then(fn conn ->
      case Keyword.get(opts, :origin) do
        nil -> conn
        origin -> put_req_header(conn, "origin", origin)
      end
    end)
    |> then(fn conn ->
      case Keyword.get(opts, :protocol) do
        nil -> conn
        version -> put_req_header(conn, "mcp-protocol-version", version)
      end
    end)
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
    |> McpPlug.call([])
  end

  defp rpc(method, params \\ %{}),
    do: post(%{jsonrpc: "2.0", id: 1, method: method, params: params})

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "a client from another address is refused" do
    assert post(%{jsonrpc: "2.0", id: 1, method: "ping"}, ip: {10, 0, 0, 5}).status == 403
  end

  test "a foreign Host is refused, so DNS rebinding cannot reach the endpoint" do
    assert post(%{jsonrpc: "2.0", id: 1, method: "ping"}, host: "evil.example").status == 403
  end

  test "a foreign Origin is refused, a loopback one and no Origin are accepted" do
    msg = %{jsonrpc: "2.0", id: 1, method: "ping"}
    assert post(msg, origin: "https://evil.example").status == 403
    assert post(msg, origin: "null").status == 403
    assert post(msg, origin: "http://localhost:4000").status == 200
    assert post(msg).status == 200
  end

  test "an MCP-Protocol-Version the server does not speak is a bad request" do
    conn = post(%{jsonrpc: "2.0", id: 1, method: "ping"}, protocol: "2026-01-01")
    assert conn.status == 400
    assert body(conn) |> get_in(["error", "code"]) == -32600
  end

  test "the protocol version the server speaks is accepted" do
    assert post(%{jsonrpc: "2.0", id: 1, method: "ping"}, protocol: "2025-06-18").status == 200
  end

  test "only POST is allowed" do
    conn = conn(:get, "/mcp") |> Map.put(:host, "localhost") |> McpPlug.call([])
    assert conn.status == 405
  end

  test "initialize names the protocol version and the tools capability" do
    result = body(rpc("initialize", %{})) |> Map.fetch!("result")
    assert result["protocolVersion"] == "2025-06-18"
    assert result["capabilities"] == %{"tools" => %{}}
    assert result["serverInfo"]["name"] == "beamdash"
  end

  test "tools/list offers the four read-only tools" do
    tools = body(rpc("tools/list")) |> get_in(["result", "tools"])

    assert Enum.sort(Enum.map(tools, & &1["name"])) ==
             ["ets_tables", "list_processes", "node_info", "process_details"]
  end

  test "a notification gets 202 and no body" do
    conn = post(%{jsonrpc: "2.0", method: "notifications/initialized"})
    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "an unknown method is a JSON-RPC error" do
    assert body(rpc("resources/list")) |> get_in(["error", "code"]) == -32601
  end

  test "an unknown tool is a JSON-RPC error, without touching the node" do
    assert body(rpc("tools/call", %{name: "kill_process", arguments: %{}}))
           |> get_in(["error", "code"]) == -32602
  end

  test "arguments that are not an object are a JSON-RPC error" do
    assert body(rpc("tools/call", %{name: "node_info", arguments: [1]}))
           |> get_in(["error", "code"]) == -32602
  end

  test "a request that is not JSON-RPC 2.0 is an invalid request" do
    conn = post(%{method: "ping", id: 1})
    assert conn.status == 400
    assert body(conn) |> get_in(["error", "code"]) == -32600
  end
end
