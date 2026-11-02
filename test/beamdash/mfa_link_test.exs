defmodule Beamdash.MfaLinkTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.{ProfileLive, TraceLive}

  @modules [{:link_probe, [{:run, 2}], []}]

  defp trace_socket do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(
      modules: @modules,
      selected: nil,
      module_filter: "",
      picked: [],
      graph: nil,
      node: nil,
      source_known: %{link_probe: false}
    )
  end

  defp profile_socket do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(
      modules: @modules,
      pick_mod: nil,
      pick_q: "",
      picked: [],
      form_error: nil,
      node: nil,
      source_known: %{link_probe: false}
    )
  end

  test "trace: a full link opens the module and picks the function" do
    {:noreply, s} =
      TraceLive.handle_params(
        %{"mod" => "link_probe", "fun" => "run", "arity" => "2"},
        "",
        trace_socket()
      )

    assert s.assigns.selected == :link_probe
    assert s.assigns.picked == [{:link_probe, :run, 2}]
  end

  test "trace: a link with mod and arity but no fun still opens the module" do
    {:noreply, s} =
      TraceLive.handle_params(%{"mod" => "link_probe", "arity" => "2"}, "", trace_socket())

    assert s.assigns.selected == :link_probe
    assert s.assigns.picked == []
  end

  test "trace: a link with mod and fun but no arity still opens the module" do
    {:noreply, s} =
      TraceLive.handle_params(%{"mod" => "link_probe", "fun" => "run"}, "", trace_socket())

    assert s.assigns.selected == :link_probe
    assert s.assigns.picked == []
  end

  test "profile: a full link opens the module and picks the function" do
    {:noreply, s} =
      ProfileLive.handle_params(
        %{"mod" => "link_probe", "fun" => "run", "arity" => "2"},
        "",
        profile_socket()
      )

    assert s.assigns.pick_mod == :link_probe
    assert s.assigns.picked == [{:link_probe, :run, 2}]
  end

  test "profile: a link with mod and arity but no fun still opens the module" do
    {:noreply, s} =
      ProfileLive.handle_params(%{"mod" => "link_probe", "arity" => "2"}, "", profile_socket())

    assert s.assigns.pick_mod == :link_probe
    assert s.assigns.picked == []
  end
end
