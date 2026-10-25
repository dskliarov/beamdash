defmodule BeamdashWeb.Connection do
  @moduledoc """
  `on_mount` hook that gives every page the connection bar
  (`BeamdashWeb.Layouts.header/1`): `@conn` holds the status, node, node
  info (OTP release, process count, memory, refreshed every 2 s), the node
  and cookie to offer in the form and a connection error. It handles the bar's `connect`
  and `disconnect` events on any tab.

  Connection events still reach the page: the hook updates `@conn` and
  lets `{:beamdash_target, _}` messages continue to the page's own
  `handle_info/2`.

  The form starts with the last node and cookie that connected
  (`Beamdash.LastConnection`, kept across restarts); a node typed in this
  session that failed to connect is offered instead until one succeeds.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_navigate: 2]

  alias Beamdash.{Format, Kubectl, LastConnection, Settings, Target}

  @refresh_ms 2_000
  @last_node {__MODULE__, :last_node}

  def on_mount(:default, _params, _session, socket) do
    %{status: status, node: node} = Target.status()
    saved = LastConnection.get()

    socket =
      socket
      |> assign(
        :conn,
        Map.merge(kube_clusters(Settings.kubeconfig_dir()), %{
          status: status,
          node: node,
          info: nil,
          node_input: if(node, do: Atom.to_string(node), else: last_node(saved.node)),
          cookie_input: saved.cookie,
          error: nil,
          method: :direct,
          kube_namespace: "",
          kube_namespaces: [],
          kube_pod: "",
          kube_pods: nil,
          kube_pods_listing: false,
          kube_containers: nil,
          kube_container: nil,
          kube_binaries: nil,
          kube_binary: nil,
          kube_listing: false
        })
      )
      |> attach_hook(:conn_event, :handle_event, &handle_event/3)
      |> attach_hook(:conn_info, :handle_info, &handle_info/2)

    if connected?(socket) do
      :ok = Target.subscribe()
      send(self(), :beamdash_conn_tick)
    end

    {:cont, socket}
  end

  @doc false
  def handle_event("connect", %{"node" => node} = params, socket) do
    node = String.trim(node)
    :persistent_term.put(@last_node, node)
    cookie = params |> Map.get("cookie", "") |> String.trim()

    case Target.connect(node, if(cookie == "", do: nil, else: cookie)) do
      {:ok, info} ->
        # remembered for the form, also after a restart
        LastConnection.put(node, if(cookie == "", do: nil, else: cookie))
        :persistent_term.erase(@last_node)

        # the page hears {:connected, node} from Target as well
        {:halt,
         socket
         |> update(
           status: :connected,
           node: info.node,
           info: info,
           error: nil,
           cookie_input: cookie
         )
         |> to_system()}

      {:error, reason} ->
        {:halt,
         update(socket, error: Format.error(reason), node_input: node, cookie_input: cookie)}
    end
  end

  def handle_event("disconnect", _params, socket) do
    :ok = Target.disconnect()
    {:halt, update(socket, status: :disconnected, node: nil, info: nil)}
  end

  # namespaces are re-listed each time Kubernetes is picked from another
  # method, so ones created meanwhile show up too
  def handle_event("set_conn_method", %{"method" => method}, socket) do
    method = String.to_existing_atom(method)
    switched? = socket.assigns.conn[:method] != method
    socket = update(socket, method: method, error: nil)
    {:halt, if(method == :kubectl and switched?, do: list_namespaces(socket), else: socket)}
  end

  # picking a different cluster invalidates everything listed under the old
  # one, same reset `"select_kube_pod"` does for a different pod.
  def handle_event("select_kube_cluster", %{"cluster" => cluster}, socket) do
    {:halt,
     socket
     |> update(
       kube_cluster: cluster,
       kube_namespaces: [],
       kube_pods: nil,
       kube_pod: "",
       kube_containers: nil,
       kube_container: nil,
       kube_binaries: nil,
       kube_binary: nil,
       error: nil
     )
     |> list_namespaces()}
  end

  def handle_event("list_kube_pods", %{"namespace" => namespace}, socket) do
    namespace = String.trim(namespace)
    cluster = socket.assigns.conn.kube_cluster

    socket =
      update(socket,
        kube_namespace: namespace,
        kube_pods_listing: true,
        kube_pods: nil,
        kube_pod: "",
        kube_containers: nil,
        kube_container: nil,
        kube_binaries: nil,
        kube_binary: nil,
        error: nil
      )

    case Kubectl.list_pods(cluster, namespace) do
      {:ok, pods} ->
        socket = update(socket, kube_pods: pods, kube_pods_listing: false)

        case pods do
          [] -> {:halt, socket}
          [pod | _] -> {:halt, list_containers(socket, cluster, namespace, pod)}
        end

      {:error, reason} ->
        {:halt, update(socket, error: Format.error(reason), kube_pods_listing: false)}
    end
  end

  # picking a different pod from the dropdown re-lists its containers and
  # `/app/bin`, same as the initial pod listing does for the first pod.
  def handle_event("select_kube_pod", %{"namespace" => namespace, "pod" => pod}, socket) do
    namespace = String.trim(namespace)
    pod = String.trim(pod)

    socket =
      update(socket,
        kube_containers: nil,
        kube_container: nil,
        kube_binaries: nil,
        kube_binary: nil,
        error: nil
      )

    {:halt, list_containers(socket, socket.assigns.conn.kube_cluster, namespace, pod)}
  end

  # the container dropdown only shows for a pod with more than one
  # container (see `Beamdash.Kubectl.list_containers/4`'s doc); picking a
  # different one re-lists `/app/bin` there.
  def handle_event(
        "select_kube_container",
        %{"namespace" => namespace, "pod" => pod, "container" => container},
        socket
      ) do
    namespace = String.trim(namespace)
    pod = String.trim(pod)

    socket = update(socket, kube_listing: true, kube_binaries: nil, kube_binary: nil, error: nil)

    {:halt,
     list_binaries(
       socket,
       socket.assigns.conn.kube_cluster,
       namespace,
       pod,
       container,
       socket.assigns.conn.kube_containers
     )}
  end

  # The pod comes from the server's selection, not the form: while a pick is
  # still being listed the browser keeps sending the previous pod's hidden field.
  def handle_event(
        "connect_kubectl",
        %{"namespace" => namespace, "container" => container, "binary" => binary},
        socket
      ) do
    namespace = String.trim(namespace)
    pod = socket.assigns.conn.kube_pod
    container = String.trim(container)
    cluster = socket.assigns.conn.kube_cluster

    case Target.connect_via_kubectl(cluster, namespace, pod, container, binary) do
      {:ok, info} ->
        # the page hears {:connected, node} from Target as well
        {:halt,
         socket
         |> update(
           status: :connected,
           node: info.node,
           info: info,
           error: nil,
           kube_namespace: namespace,
           kube_pod: pod,
           kube_container: container,
           kube_binary: binary
         )
         |> to_system()}

      {:error, reason} ->
        {:halt,
         update(socket,
           error: Format.error(reason),
           kube_namespace: namespace,
           kube_pod: pod,
           kube_container: container,
           kube_binary: binary
         )}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  @doc false
  def handle_info(:beamdash_conn_tick, socket) do
    Process.send_after(self(), :beamdash_conn_tick, @refresh_ms)
    {:halt, refresh(socket)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do:
      {:cont,
       socket
       |> update(status: :connected, node: node, error: nil, node_input: Atom.to_string(node))
       |> refresh()}

  def handle_info({:beamdash_target, {:disconnected, reason}}, socket) do
    error = if reason == :nodedown, do: "Lost the connection to #{socket.assigns.conn.node}."
    {:cont, update(socket, status: :disconnected, node: nil, info: nil, error: error)}
  end

  # Broadcast on the "settings" topic, which `BeamdashWeb.Syntax` (mounted
  # before this hook) subscribes to. A new directory re-lists the clusters
  # and drops everything listed under the old ones, same as
  # "select_kube_cluster". A page can define `kubeconfig_dir_changed/2` to
  # follow the change as well.
  def handle_info({:beamdash_kubeconfig_dir, dir}, socket) do
    socket =
      if function_exported?(socket.view, :kubeconfig_dir_changed, 2),
        do: socket.view.kubeconfig_dir_changed(socket, dir),
        else: socket

    socket =
      socket
      |> update(
        kube_namespaces: [],
        kube_pods: nil,
        kube_pod: "",
        kube_containers: nil,
        kube_container: nil,
        kube_binaries: nil,
        kube_binary: nil,
        error: nil
      )
      |> update(kube_clusters(dir))

    {:halt,
     if(socket.assigns.conn[:method] == :kubectl, do: list_namespaces(socket), else: socket)}
  end

  # the background listing started by `list_namespaces/1`; a reply for a
  # cluster no longer picked is dropped
  def handle_info({:beamdash_kube_namespaces, cluster, result}, socket) do
    if cluster == socket.assigns.conn.kube_cluster do
      namespaces =
        case result do
          {:ok, names} -> names
          {:error, _} -> []
        end

      {:halt, update(socket, kube_namespaces: namespaces)}
    else
      {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  defp refresh(%{assigns: %{conn: %{status: :connected}}} = socket) do
    case Target.node_info() do
      {:ok, info} -> update(socket, info: info)
      {:error, _} -> socket
    end
  end

  defp refresh(socket), do: socket

  # Suggestions for the namespace field, listed in the background so a slow
  # kubectl doesn't block the page; the reply arrives as
  # `{:beamdash_kube_namespaces, cluster, result}`. A cluster that forbids
  # listing namespaces (RBAC) just offers none, without an error: the field
  # still takes whatever name is typed.
  defp list_namespaces(%{assigns: %{conn: %{kube_cluster: nil}}} = socket),
    do: update(socket, kube_namespaces: [])

  defp list_namespaces(socket) do
    cluster = socket.assigns.conn.kube_cluster
    pid = self()

    {:ok, _} =
      Task.start(fn ->
        send(pid, {:beamdash_kube_namespaces, cluster, Kubectl.list_namespaces(cluster)})
      end)

    update(socket, kube_namespaces: [])
  end

  # Lists `pod`'s containers and then `/app/bin` in the first one, storing
  # `pod` itself (shared by the initial pod listing and picking a different
  # pod from the dropdown).
  defp list_containers(socket, cluster, namespace, pod) do
    socket = update(socket, kube_pod: pod, kube_listing: true)

    case Kubectl.list_containers(cluster, namespace, pod) do
      {:ok, containers} ->
        list_binaries(socket, cluster, namespace, pod, List.first(containers), containers)

      {:error, reason} ->
        update(socket, error: Format.error(reason), kube_listing: false)
    end
  end

  # Lists `/app/bin` in `container` and fills `kube_binaries`/`kube_binary`,
  # also storing the full container list and the one picked (shared by
  # `list_containers/4` and "select_kube_container").
  defp list_binaries(socket, cluster, namespace, pod, container, containers) do
    socket = update(socket, kube_containers: containers, kube_container: container)

    case Kubectl.list_binaries(cluster, namespace, pod, container) do
      {:ok, binaries} ->
        update(socket,
          kube_binaries: binaries,
          kube_binary: List.first(binaries),
          kube_listing: false
        )

      {:error, reason} ->
        update(socket, error: Format.error(reason), kube_listing: false)
    end
  end

  # Read at mount and when the directory changes in Settings, not re-listed
  # on every render: the set of kubeconfig files rarely changes mid-session.
  defp kube_clusters(dir) do
    {clusters, error} =
      case Kubectl.list_kubeconfigs(dir) do
        {:ok, clusters} -> {clusters, nil}
        {:error, reason} -> {[], Format.error(reason)}
      end

    %{
      kube_dir: dir,
      kube_clusters: clusters,
      kube_cluster: clusters |> List.first() |> then(&(&1 && &1.path)),
      kube_cluster_error: error
    }
  end

  # A connect from the bar lands on the System tab, the node's overview
  # (staying put when already there).
  defp to_system(%{view: BeamdashWeb.SystemLive} = socket), do: socket
  defp to_system(socket), do: push_navigate(socket, to: "/system")

  defp update(socket, changes),
    do: assign(socket, :conn, Map.merge(socket.assigns.conn, Map.new(changes)))

  @doc "Forgets a node typed in this session that did not connect."
  def forget_typed do
    :persistent_term.erase(@last_node)
    :ok
  end

  defp last_node(saved), do: :persistent_term.get(@last_node, saved)
end
