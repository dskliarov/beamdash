defmodule Beamdash.ConnectionBarTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Beamdash.{LastConnection, Target}
  alias BeamdashWeb.Connection
  alias Beamdash.Test.Fixture

  @endpoint BeamdashWeb.Endpoint
  @tabs ~w(/ /system /nodes /load /apps /memory /logs /gc /trace /seq /profile /crashes /settings)

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

  test "connecting from the bar moves to the System tab, unless already there", %{node: node} do
    params = %{"node" => Atom.to_string(node), "cookie" => Fixture.cookie()}

    {:halt, s} = Connection.handle_event("connect", params, socket())
    assert s.redirected == {:live, :redirect, %{kind: :push, to: "/system"}}

    :ok = Target.disconnect()
    on_system = %{socket() | view: BeamdashWeb.SystemLive}
    {:halt, s} = Connection.handle_event("connect", params, on_system)
    assert s.assigns.conn.status == :connected
    assert s.redirected == nil

    # a failed connect stays put
    {:halt, s} =
      Connection.handle_event("connect", %{"node" => "nobody@nowhere", "cookie" => "x"}, socket())

    assert s.redirected == nil
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

  test "a lost connection being tried again shows in the bar, with Stop" do
    next_at = ~U[2026-10-26 12:00:05Z]

    conn =
      Map.put(socket().assigns.conn, :reconnecting, %{
        node: :"kv1@127.0.0.1",
        attempt: 3,
        error: :connect_failed,
        next_at: next_at
      })

    html = bar(Phoenix.Component.assign(socket(), :conn, conn))
    assert html =~ ~s(class="reconnecting")
    assert html =~ ~r/Reconnecting to <strong>kv1@127.0.0.1<\/strong>\s*· try 3 at 12:00:05 UTC/
    assert html =~ "last try: Could not connect."
    assert html =~ ~s(phx-click="stop_reconnect")

    {:halt, s} = Connection.handle_event("stop_reconnect", %{}, socket())
    assert s.assigns.conn.reconnecting == nil
    refute bar(s) =~ ~s(class="reconnecting")
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

  test "a connection saved before the renames to beamdash is still found" do
    default = Path.join(:filename.basedir(:user_config, "beamdash"), "last_connection.json")
    old = &Path.join(:filename.basedir(:user_config, &1), "last_connection.json")
    assert LastConnection.legacy_paths(default) == [old.("exberly"), old.("elixberly")]
    assert LastConnection.legacy_paths("/somewhere/else.json") == []
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

  # an empty kubeconfig: a real kubectl, if present, fails fast instead of
  # reaching a cluster; only the shape of its reply is asserted
  defp empty_kubeconfig do
    path =
      Path.join(System.tmp_dir!(), "beamdash-empty-#{System.unique_integer([:positive])}.yaml")

    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp on_cluster(path, changes \\ %{}) do
    conn =
      socket().assigns.conn
      |> Map.merge(%{method: :direct, kube_cluster: path, kube_namespaces: ["stale"]})
      |> Map.merge(changes)

    Phoenix.Component.assign(socket(), :conn, conn)
  end

  test "switching to Kubernetes returns at once and lists namespaces in the background" do
    path = empty_kubeconfig()

    {:halt, s} =
      Connection.handle_event("set_conn_method", %{"method" => "kubectl"}, on_cluster(path))

    assert s.assigns.conn.method == :kubectl
    assert s.assigns.conn.kube_namespaces == []
    assert s.assigns.conn.error == nil
    assert_receive {:beamdash_kube_namespaces, ^path, _result}, 10_000

    {:halt, s} = Connection.handle_event("set_conn_method", %{"method" => "direct"}, s)
    assert s.assigns.conn.method == :direct
  end

  test "clicking Kubernetes while already on it does not list again" do
    path = empty_kubeconfig()

    {:halt, s} =
      Connection.handle_event("set_conn_method", %{"method" => "kubectl"}, on_cluster(path))

    assert_receive {:beamdash_kube_namespaces, ^path, _result}, 10_000

    {:halt, s} = Connection.handle_event("set_conn_method", %{"method" => "kubectl"}, s)
    assert s.assigns.conn.method == :kubectl
    refute_receive {:beamdash_kube_namespaces, _, _}, 300
  end

  test "a namespace listing for the current cluster fills the suggestions, quietly on failure" do
    path = "/k/prod.yaml"
    s = on_cluster(path, %{method: :kubectl, kube_namespaces: []})

    assert {:halt, ok} =
             Connection.handle_info(
               {:beamdash_kube_namespaces, path, {:ok, ["default", "pace-keeper"]}},
               s
             )

    assert ok.assigns.conn.kube_namespaces == ["default", "pace-keeper"]

    assert {:halt, failed} =
             Connection.handle_info({:beamdash_kube_namespaces, path, {:error, :x}}, ok)

    assert failed.assigns.conn.kube_namespaces == []
    assert failed.assigns.conn.error == nil
  end

  test "a namespace listing for another cluster is ignored" do
    s = on_cluster("/k/prod.yaml", %{method: :kubectl, kube_namespaces: ["default"]})

    assert {:halt, s} =
             Connection.handle_info(
               {:beamdash_kube_namespaces, "/other.yaml", {:ok, ["kube-system"]}},
               s
             )

    assert s.assigns.conn.kube_namespaces == ["default"]
  end

  test "picking another cluster clears the suggestions and lists the new one's" do
    old = empty_kubeconfig()
    new = empty_kubeconfig()
    s = on_cluster(old, %{method: :kubectl, kube_namespaces: ["default"]})

    {:halt, s} = Connection.handle_event("select_kube_cluster", %{"cluster" => new}, s)
    assert s.assigns.conn.kube_cluster == new
    assert s.assigns.conn.kube_namespaces == []
    assert s.assigns.conn.error == nil
    assert_receive {:beamdash_kube_namespaces, ^new, _result}, 10_000
  end

  test "a freshly mounted bar offers no namespaces yet" do
    assert mounted_bar().assigns.conn.kube_namespaces == []
  end

  defp kube_socket(namespaces) do
    Phoenix.Component.assign(
      socket(),
      :conn,
      Map.merge(socket().assigns.conn, %{
        method: :kubectl,
        kube_clusters: [%{name: "prod", path: "/k/prod.yaml"}],
        kube_cluster: "/k/prod.yaml",
        kube_namespace: "",
        kube_namespaces: namespaces
      })
    )
  end

  test "the namespace field suggests the cluster's namespaces and still takes any name" do
    html = bar(kube_socket(["default", "pace-keeper"]))
    assert html =~ ~s(id="kube-namespace")
    assert html =~ ~s(list="kube-namespace-list")
    assert html =~ ~s(phx-hook="NamespacePick")
    assert html =~ ~s(<datalist id="kube-namespace-list">)
    assert html =~ ~s(<option value="pace-keeper">)
    assert html =~ ~r/>\s*Cluster\s*</
    assert html =~ ~r/>\s*Namespace\s*</

    html = bar(kube_socket([]))
    assert html =~ ~s(id="kube-namespace")
    refute html =~ "<datalist"
    refute html =~ ~s(list="kube-namespace-list")
  end

  test "Direct shows labelled Node and Cookie fields" do
    html = bar(socket())
    assert html =~ ~r/>\s*Node\s*</
    assert html =~ ~r/>\s*Cookie\s*</
    assert html =~ ~s(class="seg method-switch")
  end
end
