defmodule Beamdash.SysPanelPendingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BeamdashWeb.SysPanel

  defp panel(pending) do
    render_component(SysPanel,
      id: "sys-panel-test",
      pid: self(),
      key: "test",
      label: "worker",
      syntax: :erlang,
      active: true,
      pending: pending
    )
  end

  test "a panel being enabled says so, instead of waiting for events" do
    html = panel(:enable)

    assert html =~ "Enabling sys:trace"
    refute html =~ "Waiting for events"
  end

  test "a panel being disabled says so" do
    assert panel(:disable) =~ "Disabling sys:trace"
  end

  test "a settled panel with no events waits for them" do
    html = panel(nil)

    refute html =~ "sys:trace…"
    assert html =~ "Waiting for events"
  end
end
