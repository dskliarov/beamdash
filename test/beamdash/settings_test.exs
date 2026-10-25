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

  describe "kubeconfig directory" do
    setup do
      on_exit(fn -> :ok = Settings.reset_kubeconfig_dir() end)
      dir = Path.join(System.tmp_dir!(), "beamdash-kube-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "defaults to ~/.kube" do
      :ok = Settings.reset_kubeconfig_dir()
      :ok = Settings.reload()
      assert Settings.kubeconfig_dir() == Path.expand("~/.kube")

      html =
        Plug.Test.conn(:get, "/settings") |> BeamdashWeb.Endpoint.call([]) |> Map.get(:resp_body)

      assert html =~ ~s(id="kubeconfig-dir")
      assert html =~ ~s(value="~/.kube")
    end

    test "saving lists clusters from the new directory and broadcasts it", %{dir: dir} do
      File.write!(Path.join(dir, "prod.yaml"), "")
      Phoenix.PubSub.subscribe(Beamdash.PubSub, "settings")
      view = BeamdashWeb.SettingsLive
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

      {:noreply, socket} =
        view.handle_event("set_kubeconfig_dir", %{"kubeconfig_dir" => " #{dir} "}, socket)

      assert Settings.kubeconfig_dir() == dir
      assert socket.assigns.kubeconfig_status == {:ok, "1 cluster found."}
      assert_receive {:beamdash_kubeconfig_dir, ^dir}
      assert {:ok, [%{name: "prod"}]} = Beamdash.Kubectl.list_kubeconfigs()

      {:noreply, socket} = view.handle_event("reset_kubeconfig_dir", %{}, socket)
      assert Settings.kubeconfig_dir() == Path.expand("~/.kube")
      assert socket.assigns.kubeconfig_dir == "~/.kube"
    end

    test "the chosen directory is still chosen after a restart", %{dir: dir} do
      view = BeamdashWeb.SettingsLive
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      {:noreply, _} = view.handle_event("set_kubeconfig_dir", %{"kubeconfig_dir" => dir}, socket)

      # a restart: only the file is left
      :ok = Settings.reload()
      assert Settings.kubeconfig_dir() == dir
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      assert socket.assigns.kubeconfig_dir == dir

      # Reset forgets it, also across a restart
      {:noreply, _} = view.handle_event("reset_kubeconfig_dir", %{}, socket)
      :ok = Settings.reload()
      assert Settings.kubeconfig_dir() == Path.expand("~/.kube")
    end

    test "saving keeps the settings file's other keys and survives a broken file", %{dir: dir} do
      path = Settings.path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ~s({"other": 1}))
      :ok = Settings.put_kubeconfig_dir(dir)
      assert %{"other" => 1, "kubeconfig_dir" => ^dir} = path |> File.read!() |> Jason.decode!()

      File.write!(path, "not json")
      :ok = Settings.reload()
      assert Settings.kubeconfig_dir() == Path.expand("~/.kube")
    end

    test "a missing directory is reported, not saved silently", %{dir: dir} do
      view = BeamdashWeb.SettingsLive
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      missing = Path.join(dir, "nope")

      {:noreply, socket} =
        view.handle_event("set_kubeconfig_dir", %{"kubeconfig_dir" => missing}, socket)

      assert {:warn, message} = socket.assigns.kubeconfig_status
      assert message =~ "enoent"
    end

    test "the directory browser walks local directories and picks one", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "clusters"))
      File.mkdir_p!(Path.join(dir, "other"))
      File.write!(Path.join(dir, "not-a-dir.yaml"), "")
      File.write!(Path.join([dir, "clusters", "prod.yaml"]), "")
      Settings.put_kubeconfig_dir(Path.join(dir, "missing/deeper"))

      view = BeamdashWeb.SettingsLive
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      assert socket.assigns.browser == nil

      # opens at the nearest existing parent of the current setting
      {:noreply, socket} = view.handle_event("browse_kubeconfig_dir", %{}, socket)
      assert socket.assigns.browser.path == dir
      assert socket.assigns.browser.subdirs == ["clusters", "other"]
      assert socket.assigns.browser.kubeconfigs == 1

      html =
        socket.assigns
        |> Map.put(:syntax, :erlang)
        |> view.render()
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ ~s(id="kubeconfig-browser")
      assert html =~ ~s(phx-value-name="clusters")

      {:noreply, socket} = view.handle_event("browse_into", %{"name" => "clusters"}, socket)
      assert socket.assigns.browser.path == Path.join(dir, "clusters")
      assert socket.assigns.browser.subdirs == []

      {:noreply, socket} = view.handle_event("browse_up", %{}, socket)
      assert socket.assigns.browser.path == dir
      {:noreply, socket} = view.handle_event("browse_into", %{"name" => "clusters"}, socket)

      {:noreply, socket} = view.handle_event("browse_pick", %{}, socket)
      assert socket.assigns.browser == nil
      assert Settings.kubeconfig_dir() == Path.join(dir, "clusters")
      assert socket.assigns.kubeconfig_status == {:ok, "1 cluster found."}

      {:noreply, socket} = view.handle_event("browse_kubeconfig_dir", %{}, socket)
      {:noreply, socket} = view.handle_event("browse_close", %{}, socket)
      assert socket.assigns.browser == nil
      assert Settings.kubeconfig_dir() == Path.join(dir, "clusters")
    end

    test "the connection bar re-lists clusters when the directory changes", %{dir: dir} do
      File.write!(Path.join(dir, "staging.yml"), "")

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:cont, socket} = BeamdashWeb.Connection.on_mount(:default, %{}, %{}, socket)
      socket = Phoenix.Component.assign(socket, :conn, %{socket.assigns.conn | kube_pod: "old"})

      {:halt, socket} =
        BeamdashWeb.Connection.handle_info({:beamdash_kubeconfig_dir, dir}, socket)

      conn = socket.assigns.conn
      assert conn.kube_dir == dir
      assert [%{name: "staging"}] = conn.kube_clusters
      assert conn.kube_cluster == Path.join(dir, "staging.yml")
      assert conn.kube_pod == ""
    end
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
