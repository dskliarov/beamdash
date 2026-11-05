defmodule BeamdashWeb.McpRouteTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint BeamdashWeb.Endpoint

  test "/mcp goes through the endpoint's JSON parsing to the MCP handler" do
    conn =
      build_conn()
      |> Map.put(:host, "localhost")
      |> post("/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/list"})

    assert conn.status == 200
    assert %{"result" => %{"tools" => [_ | _]}} = json_response(conn, 200)
  end

  test "/mcp refuses a request from a foreign Origin" do
    conn =
      build_conn()
      |> Map.put(:host, "localhost")
      |> put_req_header("origin", "https://evil.example")
      |> post("/mcp", %{jsonrpc: "2.0", id: 1, method: "ping"})

    assert conn.status == 403
  end
end
