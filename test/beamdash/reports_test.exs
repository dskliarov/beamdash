defmodule Beamdash.ReportsTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Reports, Settings, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "beamdash_reports_#{System.unique_integer([:positive])}")
    previous = Settings.snapshots_enabled?()
    on_exit(fn -> File.rm_rf(dir) end)
    on_exit(fn -> :ok = Settings.update_report_clients(fn _ -> [] end) end)
    on_exit(fn -> :ok = Settings.put_snapshots_enabled(previous) end)
    %{dir: dir}
  end

  defp start_store(dir) do
    start_supervised!({Store, path: Path.join(dir, "events.sqlite3"), purge_interval: :infinity})
  end

  defp client!(name \\ "laptop") do
    {:ok, token} = Reports.create_client(name)
    {:ok, client} = Reports.authenticate(token)
    {token, client}
  end

  defp finding do
    %{
      "severity" => "high",
      "type" => "bottleneck",
      "title" => "Mailbox backlog",
      "evidence" => "<0.512.0> has 48,310 messages",
      "verdict" => "The worker calls the payment API synchronously.",
      "source" => "lib/orders/worker.ex:88",
      "fix" => "Move the call into a Task.",
      "verify" => "Watch the mailbox length of <0.512.0>."
    }
  end

  defp report(overrides \\ %{}) do
    Map.merge(
      %{
        "run_id" => "run-1",
        "subject" => "triage",
        "verdict" => "needs_attention",
        "summary" => "Mailbox backlog in orders_worker.",
        "findings" => [finding()],
        "healthy" => ["No crash loops."],
        "not_checked" => ["The source is not under the source path."]
      },
      overrides
    )
  end

  test "the token is returned once, and only its hash is saved" do
    {:ok, token} = Reports.create_client("laptop")

    assert "bdr_" <> _ = token
    assert [%{"name" => "laptop"}] = Reports.clients()
    refute Map.has_key?(hd(Reports.clients()), "hash")
    refute File.read!(Settings.path()) =~ token
  end

  test "concurrent client creates all keep their place" do
    1..20
    |> Task.async_stream(&Reports.create_client("client #{&1}"))
    |> Stream.run()

    assert length(Reports.clients()) == 20
  end

  test "a blank client name is refused" do
    assert {:error, "Give the client a name" <> _} = Reports.create_client("  ")
    assert Reports.clients() == []
  end

  test "a token authenticates its client until the client is revoked" do
    {token, client} = client!()

    assert {:ok, ^client} = Reports.authenticate(token)
    assert :error = Reports.authenticate("bdr_wrong")
    assert :error = Reports.authenticate(nil)

    :ok = Reports.revoke_client(client["id"])
    assert :error = Reports.authenticate(token)
  end

  test "a valid report is stored whether or not snapshot collection is on", %{dir: dir} do
    start_store(dir)
    :ok = Settings.put_snapshots_enabled(false)
    {_token, client} = client!()

    assert {:ok, "run-1", :stored} = Reports.publish(client, report(), "app@host")

    assert [row] = Store.query(:ai_analyses)
    assert row.subject == "triage"
    assert row.node == "app@host"
    assert row.data["verdict"] == "needs_attention"
    assert row.data["client"] == "laptop"
    assert [%{"title" => "Mailbox backlog", "severity" => "high"}] = row.data["findings"]
  end

  test "a repeat of a run from the same client is not stored twice", %{dir: dir} do
    start_store(dir)
    {_token, client} = client!()

    assert {:ok, "run-1", :stored} = Reports.publish(client, report(), "app@host")
    assert {:ok, "run-1", :existing} = Reports.publish(client, report(), "app@host")
    assert [_] = Store.query(:ai_analyses)
  end

  test "concurrent repeats of a run are stored once", %{dir: dir} do
    start_store(dir)
    {_token, client} = client!()

    results =
      1..20
      |> Task.async_stream(fn _ -> Reports.publish(client, report(), "app@host") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, "run-1", :stored}, &1)) == 1
    assert [_] = Store.query(:ai_analyses)
  end

  test "another client's run with the same run_id is stored", %{dir: dir} do
    start_store(dir)
    {_, laptop} = client!("laptop")
    {_, desk} = client!("desk")

    assert {:ok, "run-1", :stored} = Reports.publish(laptop, report(), "app@host")
    assert {:ok, "run-1", :stored} = Reports.publish(desk, report(), "app@host")
    assert [_, _] = Store.query(:ai_analyses)
  end

  test "an app subject is accepted", %{dir: dir} do
    start_store(dir)
    {_token, client} = client!()

    assert {:ok, _, :stored} =
             Reports.publish(client, report(%{"subject" => "app:pace_keeper_core"}), "app@host")
  end

  test "an invalid report says what is wrong and stores nothing", %{dir: dir} do
    start_store(dir)
    {_token, client} = client!()

    assert {:error, "verdict must be one of: " <> _} =
             Reports.publish(client, report(%{"verdict" => "fine"}), "app@host")

    assert {:error, "subject must be" <> _} =
             Reports.publish(client, report(%{"subject" => "rm -rf"}), "app@host")

    assert {:error, "run_id is required"} =
             Reports.publish(client, report(%{"run_id" => ""}), "app@host")

    bad_severity = Map.put(finding(), "severity", "huge")

    assert {:error, "severity must be" <> _} =
             Reports.publish(client, report(%{"findings" => [bad_severity]}), "app@host")

    too_many = List.duplicate(finding(), 51)

    assert {:error, "findings must be" <> _} =
             Reports.publish(client, report(%{"findings" => too_many}), "app@host")

    assert {:error, "the report must be a JSON object"} =
             Reports.publish(client, "text", "app@host")

    assert [] = Store.query(:ai_analyses)
  end

  test "a report is refused with a clear error while the event store is not running" do
    {_token, client} = client!()

    assert {:error, :store_down} = Reports.publish(client, report(), "app@host")
  end
end
