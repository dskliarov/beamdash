defmodule Beamdash.SettingsTest do
  use ExUnit.Case, async: false
  alias Beamdash.{GCAdvisor, Settings}

  setup do
    previous = Settings.jev_enabled?()
    on_exit(fn -> Settings.put_jev_enabled(previous) end)
    Settings.put_jev_enabled(true)
    Beamdash.Test.Fixture.put_jev_config(api_key: "test-key")
  end

  test "settings switch changes the shared value and broadcasts it" do
    Phoenix.PubSub.subscribe(Beamdash.PubSub, "settings")
    view = BeamdashWeb.SettingsLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    assert socket.assigns.jev_enabled
    {:noreply, socket} = view.handle_event("toggle_jev", %{}, socket)
    refute Settings.jev_enabled?()
    refute socket.assigns.jev_enabled
    assert_receive {:beamdash_jev, false}
    {:noreply, socket} = view.handle_event("toggle_jev", %{}, socket)
    assert Settings.jev_enabled?()
    assert socket.assigns.jev_enabled
    assert_receive {:beamdash_jev, true}
  end

  test "until switched, Jev is on only when an API key is configured" do
    :persistent_term.erase({Settings, :jev_enabled})
    assert Settings.jev_enabled?() == Beamdash.Jev.configured?()

    previous = Application.get_env(:beamdash, Beamdash.Jev, [])
    on_exit(fn -> Application.put_env(:beamdash, Beamdash.Jev, previous) end)
    Application.put_env(:beamdash, Beamdash.Jev, Keyword.put(previous, :api_key, "k"))
    assert Settings.jev_enabled?()
    Application.put_env(:beamdash, Beamdash.Jev, Keyword.put(previous, :api_key, nil))
    refute Settings.jev_enabled?()
    Settings.put_jev_enabled(true)
    assert Settings.jev_enabled?()
  end

  test "disabled setting blocks the API client even with a key" do
    Settings.put_jev_enabled(false)

    assert {:error, message} =
             GCAdvisor.analyze(%{},
               api_key: "test-key",
               request: fn _, _, _, _ -> flunk("Disabled Jev must not make a request") end
             )

    assert message =~ "off"
  end

  test "settings route renders an accessible switch and current state" do
    Settings.put_jev_enabled(false)
    conn = Plug.Test.conn(:get, "/settings") |> BeamdashWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body =~ ~s(role="switch")
    assert conn.resp_body =~ ~s(aria-checked="false")
    assert conn.resp_body =~ "Enable Jev analysis"
    assert conn.resp_body =~ "Disabled"
    assert conn.resp_body =~ ~s(href="/settings")
  end

  test "GC page disables analysis and clears old advice when Jev is switched off" do
    view = BeamdashWeb.GCLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        selected: self(),
        detail: Beamdash.Test.Fixture.gc_detail(),
        advisor: %{title: "old advice"},
        advisor_evidence: %{old: true},
        samples: [%{offset_ms: 0}],
        events: [%{kind: :major, duration_us: 10, before: 100, after: 50}]
      )

    Settings.put_jev_enabled(false)
    socket = socket |> Phoenix.Component.assign(jev_enabled: false) |> view.jev_changed()
    assert socket.assigns.advisor == nil
    assert socket.assigns.advisor_evidence == nil
    assert socket.assigns.samples == [%{offset_ms: 0}]
    assert length(socket.assigns.events) == 1
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ "Jev"
    refute html =~ ~s(id="jev-gc")
    refute html =~ ~s(phx-click="analyze_gc")
    assert html =~ ~s(id="gc-force-collect")
  end
end
