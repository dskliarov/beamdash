defmodule BeamdashWeb.PickParamsTest do
  use ExUnit.Case, async: false

  alias BeamdashWeb.{PickParams, ProfileLive, TraceLive}

  @modules [{:lists, [seq: 2], [helper: 0]}, {:maps, [get: 2], []}]

  defp query(path) do
    [_, query] = String.split(path, "?", parts: 2)
    URI.decode_query(query)
  end

  defp socket do
    %Phoenix.LiveView.Socket{private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}}
  end

  test "the picker state survives the trip through a path" do
    state = %{
      mod: :lists,
      q: "li",
      fq: "seq",
      ff: :picked,
      picked: [{:lists, :seq, 2}, {:maps, :_, :_}]
    }

    path = PickParams.path("/profile", state)
    assert String.starts_with?(path, "/profile?")
    assert PickParams.decode(query(path), @modules) == state
  end

  test "the Tracing tab's traced filter is passed as picked" do
    path = PickParams.path("/profile", %{mod: nil, q: "", fq: "", ff: :traced, picked: []})
    assert query(path)["ff"] == "picked"
    assert PickParams.decode(query(path), @modules).ff == :picked
  end

  test "functions and modules that are not loaded are left out" do
    params = %{
      "mod" => "nope",
      "ff" => "all",
      "picked" => "lists:nope/9,nope:x/1,lists:seq/2,maps:get/2,lists:_/_"
    }

    decoded = PickParams.decode(params, @modules)
    assert decoded.mod == nil
    assert decoded.picked == [{:lists, :seq, 2}, {:maps, :get, 2}, {:lists, :_, :_}]
  end

  test "the Tracing tab applies the Profile tab's filters" do
    {:ok, socket} = TraceLive.mount(%{}, %{}, socket())
    socket = Phoenix.Component.assign(socket, modules: @modules)

    params = %{
      "mod" => "lists",
      "q" => "li",
      "fq" => "seq",
      "ff" => "picked",
      "picked" => "lists:seq/2"
    }

    {:noreply, applied} = TraceLive.handle_params(params, "", socket)

    assert applied.assigns.selected == :lists
    assert applied.assigns.module_filter == "li"
    assert applied.assigns.fn_query == "seq"
    assert applied.assigns.fn_filter == :traced
    assert applied.assigns.picked == [{:lists, :seq, 2}]
  end

  test "the Profile tab applies the Tracing tab's filters" do
    {:ok, socket} = ProfileLive.mount(%{}, %{}, socket())
    socket = Phoenix.Component.assign(socket, modules: @modules)

    params = %{
      "mod" => "maps",
      "q" => "ma",
      "fq" => "get",
      "ff" => "exported",
      "picked" => "maps:_/_"
    }

    {:noreply, applied} = ProfileLive.handle_params(params, "", socket)

    assert applied.assigns.pick_mod == :maps
    assert applied.assigns.pick_q == "ma"
    assert applied.assigns.fq == "get"
    assert applied.assigns.ff == :exported
    assert applied.assigns.picked == [{:maps, :_, :_}]
  end

  test "filters that arrive before the module list wait for it" do
    {:ok, socket} = ProfileLive.mount(%{}, %{}, socket())
    params = %{"mod" => "maps", "ff" => "all", "picked" => "maps:get/2"}

    {:noreply, waiting} = ProfileLive.handle_params(params, "/profile", socket)
    assert waiting.assigns.picked == []
    assert {^params, "/profile"} = waiting.assigns.link
  end
end
