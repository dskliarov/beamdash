defmodule Beamdash.ConnectionBarTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Beamdash.{LastConnection, Target}
  alias BeamdashWeb.Connection
  alias Beamdash.Test.Fixture

  @endpoint BeamdashWeb.Endpoint
  @tabs ~w(/ /system /load /apps /memory /gc /trace /seq /profile /crashes /settings)

  setup do
    Target.disconnect()
    {peer, node} = Fixture.start_peer()

    on_exit(fn ->
      Target.disconnect()
      Fixture.stop_peer(peer)
    end)

    %{node: node}
  end

  test "every tab shows node, cookie and Connect while disconnected" do
    for path <- @tabs do
      html = build_conn() |> get(path) |> html_response(200)
      assert html =~ ~s(id="connect-form"), path
      assert html =~ ~s(name="cookie"), path
      refute html =~ "Disconnect", path
    end
  end

  defp socket do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:conn, %{
      status: :disconnected,
      node: nil,
      info: nil,
      node_input: "",
      error: nil
    })
  end

  defp bar(socket) do
    assigns = %{active: :gc, syntax: :erlang, conn: socket.assigns.conn}
    assigns |> BeamdashWeb.Layouts.header() |> rendered_to_string()
  end

  test "Connect, node info, then Disconnect, as the bar shows them", %{node: node} do
    :ok = Target.subscribe()

    {:halt, s} =
      Connection.handle_event(
        "connect",
        %{"node" => Atom.to_string(node), "cookie" => Fixture.cookie()},
        socket()
      )

    assert s.assigns.conn.status == :connected
    html = bar(s)
    assert html =~ Atom.to_string(node)
    assert html =~ "Disconnect"
    assert html =~ ~r/OTP \d+/
    assert html =~ ~r/[\d,]+ processes/
    assert html =~ "memory"
    refute html =~ ~s(id="connect-form")

    # the page still hears the event; the hook keeps the info current
    assert_receive {:beamdash_target, {:connected, ^node}} = event
    assert {:cont, s} = Connection.handle_info(event, s)
    assert {:halt, s} = Connection.handle_info(:beamdash_conn_tick, s)
    assert s.assigns.conn.info.process_count > 0

    {:halt, s} = Connection.handle_event("disconnect", %{}, s)
    html = bar(s)
    assert html =~ ~s(id="connect-form")
    # the node typed last is offered again
    assert html =~ ~s(value="#{node}")
    refute html =~ "Disconnect"
  end

  test "another tab's disconnect, or a lost node, updates the bar", %{node: node} do
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())

    s =
      socket()
      |> Phoenix.Component.assign(:conn, %{socket().assigns.conn | status: :connected, node: node})

    assert {:cont, s2} = Connection.handle_info({:beamdash_target, {:disconnected, :user}}, s)
    assert s2.assigns.conn.status == :disconnected
    assert s2.assigns.conn.error == nil

    assert {:cont, s3} =
             Connection.handle_info({:beamdash_target, {:disconnected, :nodedown}}, s)

    assert bar(s3) =~ "Lost the connection to #{node}"
  end

  test "a failed connect shows the error in the bar" do
    {:halt, s} =
      Connection.handle_event("connect", %{"node" => "nobody@nowhere", "cookie" => "x"}, socket())

    assert s.assigns.conn.status == :disconnected
    html = bar(s)
    assert html =~ ~s(class="error conn-error")
    assert html =~ ~s(id="connect-form")
    assert html =~ ~s(value="nobody@nowhere")
  end

  defp mounted_bar do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:cont, s} = Connection.on_mount(:default, %{}, %{}, socket)
    s
  end

  test "the last node and cookie that connected are offered again, also after a restart",
       %{node: node} do
    :ok = LastConnection.forget()
    :ok = Connection.forget_typed()
    path = LastConnection.path()
    assert mounted_bar().assigns.conn.node_input == ""

    {:halt, _} =
      Connection.handle_event(
        "connect",
        %{"node" => " #{node} ", "cookie" => Fixture.cookie()},
        socket()
      )

    assert LastConnection.get() == %{node: Atom.to_string(node), cookie: Fixture.cookie()}
    # owner-only: the cookie gives full control of the node
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700

    :ok = Target.disconnect()
    # a restart: only the file is left
    :ok = LastConnection.reload()
    s = mounted_bar()
    assert s.assigns.conn.node_input == Atom.to_string(node)
    assert s.assigns.conn.cookie_input == Fixture.cookie()
    html = bar(s)
    assert html =~ ~s(value="#{node}")
    assert html =~ ~s(value="#{Fixture.cookie()}")

    # a failed attempt is shown in its form but does not replace what is saved
    {:halt, failed} =
      Connection.handle_event("connect", %{"node" => "nobody@nowhere", "cookie" => "x"}, s)

    assert failed.assigns.conn.cookie_input == "x"
    :ok = LastConnection.reload()
    assert LastConnection.get().node == Atom.to_string(node)

    # Forget in Settings empties the saved values and this page's form
    view = BeamdashWeb.SettingsLive
    {:ok, settings} = view.mount(%{}, %{}, socket())
    settings = Phoenix.Component.assign(settings, syntax: :erlang)
    html = view.render(settings.assigns) |> rendered_to_string()
    assert html =~ "cookie saved"
    assert html =~ ~s(id="forget-connection")
    refute html =~ Fixture.cookie()

    {:noreply, settings} = view.handle_event("forget_connection", %{}, settings)
    assert settings.assigns.conn.node_input == ""
    assert settings.assigns.conn.cookie_input == ""
    refute File.exists?(path)
    assert view.render(settings.assigns) |> rendered_to_string() =~ "Nothing saved yet"
    :ok = LastConnection.reload()
    assert LastConnection.get() == %{node: "", cookie: ""}
  end

  test "a connection saved before the rename to beamdash is still found" do
    default = Path.join(:filename.basedir(:user_config, "beamdash"), "last_connection.json")
    old = Path.join(:filename.basedir(:user_config, "exberly"), "last_connection.json")
    assert LastConnection.legacy_path(default) == old
    assert LastConnection.legacy_path("/somewhere/else.json") == nil
  end

  test "remembering can be turned off in the configuration", %{node: node} do
    previous = Application.get_env(:beamdash, :last_connection_file)
    on_exit(fn -> Application.put_env(:beamdash, :last_connection_file, previous) end)
    :ok = LastConnection.forget()
    Application.put_env(:beamdash, :last_connection_file, false)
    :ok = LastConnection.reload()

    {:halt, _} =
      Connection.handle_event(
        "connect",
        %{"node" => Atom.to_string(node), "cookie" => ""},
        socket()
      )

    refute File.exists?(previous)
    :ok = LastConnection.reload()
    assert LastConnection.get().node == ""
  end

  test "the kubectl method is labelled Kubernetes when kubectl was found at startup" do
    previous = Application.get_env(:beamdash, :has_k8s)
    on_exit(fn -> Application.put_env(:beamdash, :has_k8s, previous) end)

    Application.put_env(:beamdash, :has_k8s, true)
    assert bar(socket()) =~ ~r/>\s*Kubernetes\s*</
    refute bar(socket()) =~ ~r/>\s*kubectl\s*</

    Application.put_env(:beamdash, :has_k8s, false)
    assert bar(socket()) =~ ~r/>\s*kubectl\s*</
    refute bar(socket()) =~ ~r/>\s*Kubernetes\s*</
  end

  test "the namespace field suggests the namespaces found in the cluster" do
    conn =
      Map.merge(socket().assigns.conn, %{
        method: :kubectl,
        kube_clusters: [%{name: "prod", path: "/k/prod.yaml"}],
        kube_cluster: "/k/prod.yaml",
        kube_namespace: "",
        kube_namespaces: ["default", "prod"]
      })

    html =
      %{active: :gc, syntax: :erlang, conn: conn}
      |> BeamdashWeb.Layouts.header()
      |> rendered_to_string()

    assert html =~ ~s(phx-hook="NamespaceCombobox")
    assert html =~ ~s(data-options="[&quot;default&quot;,&quot;prod&quot;]")
    assert html =~ ~s(role="combobox")
    assert html =~ ~s(id="namespace-options")
  end

  test "other events and messages pass through to the page" do
    assert {:cont, _} = Connection.handle_event("sort", %{}, socket())
    assert {:cont, _} = Connection.handle_info(:tick, socket())
  end

  test "subscribing twice from one process sends each event once", %{node: node} do
    :ok = Target.subscribe()
    :ok = Target.subscribe()
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())
    assert_receive {:beamdash_target, {:connected, ^node}}
    refute_receive {:beamdash_target, {:connected, ^node}}, 200
  end
end
