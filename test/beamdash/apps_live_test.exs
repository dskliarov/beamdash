defmodule Beamdash.AppsLiveTest do
  # The Apps tab against this node, which always runs kernel.
  use ExUnit.Case, async: true

  alias BeamdashWeb.AppsLive
  alias Phoenix.Component

  defp cold_socket do
    Component.assign(%Phoenix.LiveView.Socket{},
      status: :connected,
      node: node(),
      apps: [],
      app: nil,
      tree: nil,
      info: nil,
      error: nil,
      selected: nil,
      proc: nil
    )
  end

  test "a ?app= link on a cold page opens that application, with its tree" do
    {:noreply, socket} =
      AppsLive.handle_params(%{"app" => "kernel"}, "http://localhost/apps", cold_socket())

    assert socket.assigns.app == :kernel
    assert socket.assigns.tree != nil
  end
end
