defmodule Beamdash.KevTest do
  # Kev: a self-hosted model serving TypeSafe's API, as a second backend
  use ExUnit.Case, async: false
  alias Beamdash.{Jev, Settings}
  alias Beamdash.Test.Fixture

  setup do
    previous = Settings.jev_enabled?()
    Settings.put_jev_enabled(true)
    Settings.put_decision_backend(nil)
    Settings.put_kev_port(nil)

    on_exit(fn ->
      Settings.put_jev_enabled(previous)
      Settings.put_decision_backend(nil)
      Settings.put_kev_port(nil)
    end)

    Fixture.put_jev_config(
      enabled: true,
      api_key: "typesafe-key",
      kev_url: "http://127.0.0.1:8009",
      kev_port: nil,
      kev_api_key: nil,
      kev_model: nil,
      kev_timeout: nil,
      backend: nil
    )
  end

  @choices %{
    "a" => %{label: "Option A", what: "covers a", not_for: "b"},
    "b" => %{label: "Option B", what: "covers b", not_for: "a"}
  }

  defp answer(model) do
    Jason.encode!(%{
      "model" => model,
      "answers" => %{
        "next_step" => %{
          "type" => "choice",
          "choice" => "a",
          "confidence" => 0.4,
          "probabilities" => %{"a" => 0.7, "b" => 0.3}
        }
      }
    })
  end

  defp capture(test_pid) do
    fn :post, {url, headers, _type, body}, options, _ ->
      send(test_pid, {:request, List.to_string(url), headers, Jason.decode!(body), options})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], answer(Jason.decode!(body)["model"])}}
    end
  end

  test "a Kev request goes to its server's /v1/systemone, without TypeSafe's key or TLS" do
    assert {:ok, %{choice: "a", model: "kev-latest"}} =
             Jev.ask(%{x: 1}, "Which?", @choices, backend: :kev, request: capture(self()))

    assert_receive {:request, "http://127.0.0.1:8009/v1/systemone", [], body, options}
    assert body["model"] == "kev-latest"
    assert body["questions"]["next_step"]["criteria"]["a"]["option"] == "Option A"
    assert options[:timeout] == 120_000
    refute Keyword.has_key?(options, :ssl)
  end

  test "Kev's own key, model and timeout; a URL may already end in /v1/systemone" do
    Fixture.put_jev_config(
      kev_url: "https://kev.example/v1/systemone/",
      kev_api_key: "kev-key",
      kev_model: "kev-9b",
      kev_timeout: "300000"
    )

    assert {:ok, _} = Jev.ask(%{}, "q", @choices, backend: :kev, request: capture(self()))
    assert_receive {:request, "https://kev.example/v1/systemone", headers, body, options}
    assert headers == [{~c"authorization", ~c"Bearer kev-key"}]
    assert body["model"] == "kev-9b"
    assert options[:timeout] == 300_000
    assert options[:ssl][:verify] == :verify_peer
    assert Jev.destination(:kev) == "Kev at kev.example"
  end

  test "Jev requests still go to TypeSafe with its key" do
    assert {:ok, _} = Jev.ask(%{}, "q", @choices, backend: :jev, request: capture(self()))
    assert_receive {:request, "https://api.typesafe.ai/v1/systemone", headers, body, options}
    assert headers == [{~c"authorization", ~c"Bearer typesafe-key"}]
    assert body["model"] == Jev.default_model()
    assert options[:timeout] == 15_000
  end

  test "the backend: chosen in Settings, else DECISION_BACKEND, else Jev, among those configured" do
    assert Jev.configured_backends() == [:jev, :kev]
    assert Jev.backend() == :jev

    Fixture.put_jev_config(backend: "kev")
    assert Jev.backend() == :kev

    Phoenix.PubSub.subscribe(Beamdash.PubSub, "settings")
    :ok = Settings.put_decision_backend(:jev)
    assert_receive {:beamdash_backend, :jev}
    assert Jev.backend() == :jev

    # saved for the next start
    Settings.reload()
    assert Settings.decision_backend() == :jev

    # a choice whose backend is no longer configured is passed over
    :ok = Settings.put_decision_backend(:kev)
    Fixture.put_jev_config(kev_url: nil)
    assert Jev.backend() == :jev
    assert Jev.configured_backends() == [:jev]
  end

  test "Kev alone makes the UI available, and the next request goes to it" do
    Fixture.put_jev_config(api_key: nil)
    assert Jev.available?()
    assert Jev.backend() == :kev
    assert Jev.name() == "Kev"
    assert {:ok, _} = Jev.ask(%{}, "q", @choices, request: capture(self()))
    assert_receive {:request, "http://127.0.0.1:8009/v1/systemone", [], _, _}
  end

  test "Kev errors name Kev; a 422 says the state may be too long" do
    status = fn code -> fn _, _, _, _ -> {:ok, {{~c"HTTP/1.1", code, ~c"E"}, [], "body"}} end end

    assert {:error, msg} = Jev.ask(%{}, "q", @choices, backend: :kev, request: status.(422))
    assert msg =~ "too long"

    assert {:error, msg} = Jev.ask(%{}, "q", @choices, backend: :kev, request: status.(401))
    assert msg =~ "KEV_API_KEY"

    timeout = fn _, _, _, _ -> {:error, :timeout} end
    assert {:error, msg} = Jev.ask(%{}, "q", @choices, backend: :kev, request: timeout)
    assert msg =~ "Kev did not answer within 120 s"

    Fixture.put_jev_config(kev_url: nil)
    never = fn _, _, _, _ -> flunk("request made") end
    assert {:error, msg} = Jev.ask(%{}, "q", @choices, backend: :kev, request: never)
    assert msg =~ "KEV_URL"
  end

  test "Settings offers both models when both are configured and switches between them" do
    view = BeamdashWeb.SettingsLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = view.handle_event("set_backend", %{"backend" => "kev"}, socket)
    assert socket.assigns.jev_backend == :kev
    assert Settings.decision_backend() == :kev
    {:noreply, socket} = view.handle_event("set_backend", %{"backend" => "nope"}, socket)
    assert socket.assigns.jev_backend == :kev
  end

  test "KEV_PORT alone is a Kev server on this machine; a bad port is not" do
    Fixture.put_jev_config(kev_url: nil, kev_port: "9100")
    assert Jev.configured?(:kev)
    assert Jev.endpoint(:kev) == "http://127.0.0.1:9100/v1/systemone"
    assert Jev.kev_port() == 9100

    Fixture.put_jev_config(kev_port: "70000")
    refute Jev.configured?(:kev)
    assert Jev.kev_port() == nil
  end

  test "the port saved in Settings replaces KEV_URL's, and empty goes back to it" do
    Fixture.put_jev_config(kev_url: "http://kev.lan:8009/")
    view = BeamdashWeb.SettingsLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} = view.handle_event("set_kev_port", %{"port" => "9200"}, socket)
    assert socket.assigns.kev_port_error == nil
    assert Jev.endpoint(:kev) == "http://kev.lan:9200/v1/systemone"

    assert {:ok, _} = Jev.ask(%{}, "q", @choices, backend: :kev, request: capture(self()))
    assert_receive {:request, "http://kev.lan:9200/v1/systemone", _, _, _}

    # saved for the next start
    Settings.reload()
    assert Settings.kev_port() == 9200

    {:noreply, socket} = view.handle_event("set_kev_port", %{"port" => "http"}, socket)
    assert socket.assigns.kev_port_error =~ "65535"
    assert Settings.kev_port() == 9200

    {:noreply, _} = view.handle_event("set_kev_port", %{"port" => " "}, socket)
    assert Settings.kev_port() == nil
    assert Jev.endpoint(:kev) == "http://kev.lan:8009/v1/systemone"
  end
end
