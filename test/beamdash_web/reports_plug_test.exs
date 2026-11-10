defmodule BeamdashWeb.ReportsPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Beamdash.{Reports, Settings, Store, Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.ReportsPlug

  defp unique_name, do: :"reports_target_#{System.unique_integer([:positive])}"

  defp start_store do
    dir =
      Path.join(System.tmp_dir!(), "beamdash_reports_plug_#{System.unique_integer([:positive])}")

    start_supervised!({Store, path: Path.join(dir, "events.sqlite3"), purge_interval: :infinity})
    on_exit(fn -> File.rm_rf(dir) end)
  end

  defp token! do
    {:ok, token} = Reports.create_client("laptop")
    token
  end

  defp report(overrides \\ %{}) do
    Map.merge(
      %{
        "run_id" => "run-1",
        "subject" => "triage",
        "verdict" => "healthy",
        "summary" => "Nothing to report.",
        "findings" => [],
        "healthy" => ["No crash loops."],
        "not_checked" => []
      },
      overrides
    )
  end

  defp post(body, opts \\ []) do
    conn(:post, "/reports", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> maybe_header("authorization", opts[:auth])
    |> Map.merge(%{remote_ip: Keyword.get(opts, :ip, {127, 0, 0, 1}), host: "localhost"})
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
    |> ReportsPlug.call(target: Keyword.get(opts, :target, Target))
  end

  defp maybe_header(conn, _name, nil), do: conn
  defp maybe_header(conn, name, value), do: put_req_header(conn, name, value)

  defp bearer(token), do: "Bearer " <> token

  defp body(conn), do: Jason.decode!(conn.resp_body)

  setup do
    on_exit(fn -> :ok = Settings.put_report_clients([]) end)
    :ok
  end

  test "a client from another address is refused" do
    token = token!()
    conn = post(report(), auth: bearer(token), ip: {10, 0, 0, 5})
    assert conn.status == 403
  end

  test "only POST is accepted" do
    conn = %{conn(:get, "/reports") | host: "localhost"} |> ReportsPlug.call(target: Target)
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  test "a body over 256 KB is refused before it is read" do
    conn =
      %{conn(:post, "/reports", "") | host: "localhost"}
      |> put_req_header("content-length", Integer.to_string(300 * 1024))
      |> put_req_header("authorization", bearer(token!()))
      |> ReportsPlug.call(target: Target)

    assert conn.status == 413
  end

  test "a request without a valid token is unauthorized" do
    conn = post(report())
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    assert post(report(), auth: bearer("bdr_wrong")).status == 401
    assert post(report(), auth: "Basic abc").status == 401
  end

  test "a revoked token is unauthorized" do
    {:ok, token} = Reports.create_client("gone")
    [client] = Enum.filter(Reports.clients(), &(&1["name"] == "gone"))
    :ok = Reports.revoke_client(client["id"])

    assert post(report(), auth: bearer(token)).status == 401
  end

  test "a report is refused with 409 while beamdash is not connected to a node" do
    target = start_supervised!({Target, name: unique_name()})

    conn = post(report(), auth: bearer(token!()), target: target)

    assert conn.status == 409
    assert body(conn)["error"] == "beamdash is not connected to a node"
  end

  describe "with a connected node" do
    setup do
      start_store()
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      target = start_supervised!({Target, name: unique_name()})
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)

      %{target: target, node: node}
    end

    test "a new report is stored with 201, and a repeat with 200", %{target: target} do
      auth = bearer(token!())

      conn = post(report(), auth: auth, target: target)
      assert conn.status == 201
      assert body(conn) == %{"run_id" => "run-1", "status" => "stored"}

      conn = post(report(), auth: auth, target: target)
      assert conn.status == 200
      assert body(conn) == %{"run_id" => "run-1", "status" => "already stored"}
    end

    test "an invalid report is refused with 422 and the reason", %{target: target} do
      conn = post(report(%{"verdict" => "fine"}), auth: bearer(token!()), target: target)

      assert conn.status == 422
      assert body(conn)["error"] =~ "verdict must be one of"
    end

    test "a report is refused with 503 while the event store is not running", %{target: target} do
      stop_supervised!(Store)

      conn = post(report(), auth: bearer(token!()), target: target)

      assert conn.status == 503
    end
  end
end
