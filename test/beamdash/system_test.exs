defmodule Beamdash.SystemTest do
  # The System tab: what Observer's System tab shows, read by the agent.
  use ExUnit.Case, async: false

  alias Beamdash.Target
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.SystemLive

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)

    target =
      start_supervised!({Target, name: :"sys_target_#{System.unique_integer([:positive])}"})

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    %{node: node, target: target}
  end

  test "the agent reads everything Observer's System tab shows", %{node: node, target: target} do
    assert {:ok, info} = Target.system_info(target)

    assert info.otp_release ==
             :erpc.call(node, :erlang, :system_info, [:otp_release]) |> to_string()

    assert is_binary(info.version) and is_binary(info.system_architecture)
    assert info.wordsize_external in [4, 8]
    assert info.schedulers_online > 0 and info.schedulers_available > 0
    assert info.process_count > 0 and info.process_limit > info.process_count
    assert info.atom_count > 0 and info.ets_count >= 0 and info.port_count > 0
    assert info.memory.total >= info.memory.processes
    assert info.uptime_ms > 0 and info.io_input >= 0 and info.run_queue >= 0
  end

  test "the page shows Observer's five panels with its labels", %{target: target} do
    {:ok, info} = Target.system_info(target)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = SystemLive.mount(%{}, %{}, socket)

    html =
      socket.assigns
      |> Map.merge(%{syntax: :erlang, status: :connected, info: info, at: DateTime.utc_now()})
      |> SystemLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    for title <- [
          "System and Architecture",
          "Memory Usage",
          "CPUs and Threads",
          "Statistics",
          "System statistics / limit"
        ],
        do: assert(html =~ title)

    for label <- ~w(ERTS\ Version Compiled\ for Online\ schedulers Run\ Queue IO\ Output Ports),
        do: assert(html =~ label)

    assert html =~ ~r/[\d,]+ \/ [\d,]+ \(\d+ % used\)/
    assert html =~ "Distribution buffer busy limit"
    assert html =~ ~s(href="/system")
  end

  test "values are written as Observer writes them" do
    assert SystemLive.uptime(90_061_000) == "1 day 1:01:01"
    assert SystemLive.uptime(5_000) == "0 days 0:00:05"
    assert SystemLive.limit_text(1_000, 1_048_576) == "1,000 / 1,048,576 (0 % used)"
    assert SystemLive.limit_text(:undefined, 10) == "Not available / 10"
  end
end
