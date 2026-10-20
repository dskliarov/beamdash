defmodule Exberly.JevHiddenTest do
  # With Jev disabled in the configuration (JEV_ENABLED=false), or without
  # an API key, nothing of Jev shows and no request is made.
  use ExUnit.Case, async: false

  alias Exberly.{Jev, Settings}
  alias Exberly.Test.Fixture

  setup do
    previous = Settings.jev_enabled?()
    Settings.put_jev_enabled(true)
    on_exit(fn -> Settings.put_jev_enabled(previous) end)
    Fixture.put_jev_config(api_key: "test-key", enabled: false)
  end

  defp render(view, assigns, jev_enabled \\ true) do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = view.mount(%{}, %{}, socket)

    socket.assigns
    |> Map.merge(%{
      syntax: :erlang,
      jev_enabled: jev_enabled,
      ask: %{query: "", busy: nil, options: [], error: nil}
    })
    |> Map.merge(assigns)
    |> view.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp pages do
    snap = %{
      memory: %{
        total: 100,
        processes: 40,
        processes_used: 40,
        system: 60,
        atom: 1,
        atom_used: 1,
        binary: 30,
        code: 10,
        ets: 10
      },
      alloc: nil,
      atom_count: 1,
      atom_limit: 10,
      process_count: 1,
      process_limit: 10,
      ets_count: 1,
      ets_limit: 10,
      module_count: 1,
      recon: false
    }

    event = %{
      id: 1,
      type: :send,
      from: "<0.1.0>",
      to: "<0.2.0>",
      message: :hi,
      timestamp_us: 1,
      serial: {1, 2}
    }

    [
      {ExberlyWeb.HomeLive, %{status: :connected, procs: []}},
      {ExberlyWeb.MemoryLive, %{status: :connected, snap: snap}},
      {ExberlyWeb.SeqLive, %{events: List.duplicate(event, 12)}},
      {ExberlyWeb.GCLive, %{status: :connected, selected: self(), detail: Fixture.gc_detail()}},
      {ExberlyWeb.TraceLive, %{}},
      {ExberlyWeb.ProfileLive, %{}},
      {ExberlyWeb.CrashLive, %{}},
      {ExberlyWeb.SystemLive, %{}},
      {ExberlyWeb.SettingsLive, %{}}
    ]
  end

  defp refute_jev(html) do
    refute html =~ "Jev"
    refute html =~ "jev-"
    refute html =~ ~s(id="ask-form")
    refute html =~ "TypeSafe"
  end

  test "available only when enabled in the configuration and a key is set" do
    refute Jev.available?()
    Fixture.put_jev_config(enabled: true)
    assert Jev.available?()
    Fixture.put_jev_config(api_key: nil)
    refute Jev.available?()
  end

  test "no request is made when disabled in the configuration" do
    assert {:error, message} =
             Jev.ask(%{}, "q", %{"a" => %{label: "A", what: "a", not_for: "b"}},
               request: fn _, _, _, _ -> flunk("request made") end
             )

    assert message =~ "configuration"
  end

  test "every page renders without Jev" do
    for {view, assigns} <- pages() do
      html = render(view, assigns)
      refute_jev(html)
    end

    refute render(ExberlyWeb.SettingsLive, %{}) =~ ~s(id="jev-setting-heading")
  end

  test "with the Settings switch off nothing of Jev shows on any tab" do
    Fixture.put_jev_config(enabled: true)
    Settings.put_jev_enabled(false)

    for {view, assigns} <- pages(), view != ExberlyWeb.SettingsLive do
      refute_jev(render(view, assigns, false))
    end

    # the switch stays in Settings so Jev can be turned back on
    settings = render(ExberlyWeb.SettingsLive, %{}, false)
    assert settings =~ "Enable Jev analysis"
    refute settings =~ ~s(id="ask-form")
  end

  test "with Jev enabled the tabs show it" do
    Fixture.put_jev_config(enabled: true)

    assert render(ExberlyWeb.SeqLive, Map.new(pages())[ExberlyWeb.SeqLive]) =~
             ~s(id="jev-seq")

    assert render(ExberlyWeb.HomeLive, %{status: :connected, procs: []}) =~ ~s(id="ask-form")
  end

  test "runtime.exs only overrides Jev settings that the environment sets" do
    vars = ~w(JEV_ENABLED TYPESAFE_API_KEY TYPESAFE_MODEL TYPESAFE_CACERTFILE TYPESAFE_ENDPOINT)
    saved = Map.new(vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(vars, &System.delete_env/1)

    jev = fn ->
      Config.Reader.read!("config/runtime.exs", env: :dev)[:exberly][Exberly.Jev]
    end

    # nothing set: config.exs (e.g. enabled: false) stays in charge
    assert jev.() == nil
    System.put_env("JEV_ENABLED", "Off")
    assert jev.() == [enabled: false]
    System.put_env("JEV_ENABLED", "true")
    assert jev.() == [enabled: true]

    assert Config.Reader.read!("config/config.exs", env: :dev)[:exberly][Exberly.Jev][
             :enabled
           ]
  end

  test "the process panel has no Jev section" do
    html =
      %{
        details:
          Map.merge(Fixture.gc_detail(), %{
            reductions: 1,
            links: [],
            monitors: [],
            monitored_by: [],
            current_stacktrace: [],
            trap_exit: false,
            priority: :normal
          }),
        __changed__: nil,
        history: [],
        syntax: :erlang,
        jev: %{
          enabled: true,
          configured: true,
          busy: false,
          readiness: {:ready, 30},
          advice: nil,
          error: nil,
          evidence: nil
        }
      }
      |> ExberlyWeb.ProcessDetails.panel()
      |> Phoenix.LiveViewTest.rendered_to_string()

    refute_jev(html)
  end
end
