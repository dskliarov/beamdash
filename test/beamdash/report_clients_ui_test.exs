defmodule Beamdash.ReportClientsUITest do
  use ExUnit.Case, async: false

  alias Beamdash.Reports
  alias BeamdashWeb.SettingsLive

  setup do
    on_exit(fn -> :ok = Beamdash.Settings.update_report_clients(fn _ -> [] end) end)
    {:ok, socket} = SettingsLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    %{socket: socket}
  end

  test "creating a client shows its token once and lists the client", %{socket: socket} do
    {:noreply, socket} =
      SettingsLive.handle_event("create_report_client", %{"name" => "desk"}, socket)

    assert "bdr_" <> _ = socket.assigns.new_report_token
    assert socket.assigns.report_client_error == nil
    assert [%{"name" => "desk"}] = socket.assigns.report_clients
    refute Map.has_key?(hd(socket.assigns.report_clients), "hash")
  end

  test "a blank client name is reported and no token is shown", %{socket: socket} do
    {:noreply, socket} =
      SettingsLive.handle_event("create_report_client", %{"name" => " "}, socket)

    assert socket.assigns.report_client_error =~ "Give the client a name"
    assert socket.assigns.new_report_token == nil
    assert Reports.clients() == []
  end

  test "revoking a client removes it and clears the token", %{socket: socket} do
    {:noreply, socket} =
      SettingsLive.handle_event("create_report_client", %{"name" => "desk"}, socket)

    [%{"id" => id}] = socket.assigns.report_clients

    {:noreply, socket} = SettingsLive.handle_event("revoke_report_client", %{"id" => id}, socket)

    assert socket.assigns.report_clients == []
    assert socket.assigns.new_report_token == nil
    assert Reports.clients() == []
  end
end
