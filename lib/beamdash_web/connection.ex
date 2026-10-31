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

  `@conn.plugins` holds the active plugins (`Beamdash.Plugins.active/1`)
  for the nav's Plugins menu, updated on `{:beamdash_plugins, :changed}`.
  A page that shows plugins can define `plugins_changed/2`: it gets the
  socket and the event (`:changed` or `{:removed, app}`) and returns the
  socket. Other `{:beamdash_plugins, _}` messages (an install's progress)
  go on to the page.

  `@conn.reconnecting` is `Beamdash.Target.reconnecting/1` while a lost
  connection is being tried again: the bar says so, with a Stop button
  (`stop_reconnect`).

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
    kube_saved = Settings.kube_selection()
    clusters = kube_clusters(Settings.kubeconfig_dir())

    cluster =
      if Enum.any?(clusters.kube_clusters, &(&1.path == kube_saved["cluster"])),
        do: kube_saved["cluster"],
        else: clusters.kube_cluster

    socket =
      socket
      |> assign(
        :conn,
        Map.merge(clusters, %{
          status: status,
          node: node,
          info: nil,
          node_input: if(node, do: Atom.to_string(node), else: last_node(saved.node)),
          cookie_input: saved.cookie,
          error: nil,
          method: :direct,
          kube_cluster: cluster,
          kube_namespace:
            if(cluster == kube_saved["cluster"], do: kube_saved["namespace"], else: ""),
          kube_namespaces: [],
          kube_pod: "",
          kube_pods: nil,
          kube_pods_listing: false,
          kube_restore_ref: nil,
          kube_containers: nil,
          kube_container: nil,
          kube_binaries: nil,
          kube_binary: nil,
          kube_listing: false,
          reconnecting: if(status == :connected, do: nil, else: Target.reconnecting()),
          plugins: active_plugins()
        })
      )
      |> attach_hook(:conn_event, :handle_event, &handle_event/3)
      |> attach_hook(:conn_info, :handle_info, &handle_info/2)

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = Phoenix.PubSub.subscribe(Beamdash.PubSub, "plugins")
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
    {:halt, update(socket, status: :disconnected, node: nil, info: nil, reconnecting: nil)}
  end

  def handle_event("stop_reconnect", _params, socket) do
    :ok = Target.stop_reconnect()
    {:halt, update(socket, reconnecting: nil)}
  end

  # namespaces are re-listed each time Kubernetes is picked from another
  # method, so ones created meanwhile show up too
  def handle_event("set_conn_method", %{"method" => method}, socket) do
    method = String.to_existing_atom(method)
    switched? = socket.assigns.conn[:method] != method
    socket = update(socket, method: method, error: nil)

    socket =
      if switched?,
        do: update(socket, kube_restore_ref: nil, kube_pods_listing: false),
        else: socket

    if method == :kubectl and switched? do
      socket = list_namespaces(socket)

      if socket.assigns.conn.kube_cluster &&
           Map.get(socket.assigns.conn, :kube_namespace, "") != "" &&
           is_nil(socket.assigns.conn[:kube_pods]) do
        cluster = socket.assigns.conn.kube_cluster
        namespace = socket.assigns.conn.kube_namespace
        saved = Settings.kube_selection()
        ref = make_ref()
        pid = self()

        {:ok, _} =
          Task.start(fn ->
            send(
              pid,
              {:beamdash_restore_kube, ref, cluster, namespace,
               restore_kube(cluster, namespace, saved)}
            )
          end)

        {:halt, update(socket, kube_pods_listing: true, kube_restore_ref: ref)}
      else
        {:halt, socket}
      end
    else
      {:halt, socket}
    end
  end

  # picking a different cluster invalidates everything listed under the old
  # one, same reset `"select_kube_pod"` does for a different pod.
  def handle_event("select_kube_cluster", %{"cluster" => cluster}, socket) do
    Settings.put_kube_selection(%{"cluster" => cluster})

    {:halt,
     socket
     |> update(
       kube_cluster: cluster,
       kube_namespace: "",
       kube_namespaces: [],
       kube_pods: nil,
       kube_pods_listing: false,
       kube_restore_ref: nil,
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
    saved = Settings.kube_selection()

    saved =
      if saved["cluster"] == cluster and saved["namespace"] == namespace,
        do: saved,
        else: %{"cluster" => cluster, "namespace" => namespace}

    Settings.put_kube_selection(saved)

    socket =
      update(socket,
        kube_namespace: namespace,
        kube_pods_listing: true,
        kube_restore_ref: nil,
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
          [] ->
            {:halt, socket}

          [first | _] ->
            pod = if saved["pod"] in pods, do: saved["pod"], else: first
            {:halt, list_containers(socket, cluster, namespace, pod)}
        end

      {:error, reason} ->
        {:halt, update(socket, error: Format.error(reason), kube_pods_listing: false)}
    end
  end

  # picking a different pod from the dropdown re-lists its containers and
  # the release binaries, same as the initial pod listing does for the first pod.
  def handle_event("select_kube_pod", %{"namespace" => namespace, "pod" => pod}, socket) do
    namespace = String.trim(namespace)
    pod = String.trim(pod)

    Settings.put_kube_selection(%{
      "cluster" => socket.assigns.conn.kube_cluster,
      "namespace" => namespace,
      "pod" => pod
    })

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
  # different one re-lists the release binaries there.
  def handle_event(
        "select_kube_container",
        %{"namespace" => namespace, "pod" => pod, "container" => container},
        socket
      ) do
    namespace = String.trim(namespace)
    pod = String.trim(pod)

    Settings.put_kube_selection(%{
      "cluster" => socket.assigns.conn.kube_cluster,
      "namespace" => namespace,
      "pod" => pod,
      "container" => container
    })

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

  def handle_event("select_kube_binary", %{"binary" => binary}, socket) do
    if binary in (socket.assigns.conn.kube_binaries || []) do
      save_kube_selection(socket, binary)
      {:halt, update(socket, kube_binary: binary)}
    else
      {:halt, socket}
    end
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
    save_kube_selection(socket, binary)

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
       |> update(
         status: :connected,
         node: node,
         error: nil,
         node_input: Atom.to_string(node),
         reconnecting: nil
       )
       |> refresh()}

  def handle_info({:beamdash_target, {:disconnected, reason}}, socket) do
    error = if reason == :nodedown, do: "Lost the connection to #{socket.assigns.conn.node}."

    {:cont,
     update(socket,
       status: :disconnected,
       node: nil,
       info: nil,
       error: error,
       reconnecting: Target.reconnecting()
     )}
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
        kube_pods_listing: false,
        kube_restore_ref: nil,
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

  def handle_info({:beamdash_restore_kube, ref, cluster, namespace, result}, socket) do
    conn = socket.assigns.conn

    if conn.kube_restore_ref == ref and conn.method == :kubectl and conn.kube_cluster == cluster and
         conn.kube_namespace == namespace and conn.kube_pods_listing and is_nil(conn.kube_pods) do
      case result do
        {status, %{pods: pods} = restored} when status in [:ok, :partial] ->
          socket =
            update(socket,
              kube_pods: pods,
              kube_pods_listing: false,
              kube_restore_ref: nil,
              kube_pod: restored[:pod] || "",
              kube_containers: restored[:containers],
              kube_container: restored[:container],
              kube_binaries: restored[:binaries],
              kube_binary: restored[:binary],
              error: if(status == :partial, do: Format.error(restored.error), else: nil)
            )

          if status == :ok and restored[:pod], do: save_kube_selection(socket, restored[:binary])
          {:halt, socket}

        {:error, reason} ->
          {:halt,
           update(socket,
             kube_pods_listing: false,
             kube_restore_ref: nil,
             error: Format.error(reason)
           )}
      end
    else
      {:halt, socket}
    end
  end

  def handle_info({:beamdash_plugins, event}, socket)
      when event == :changed or (is_tuple(event) and elem(event, 0) == :removed) do
    socket = update(socket, plugins: active_plugins())

    socket =
      if function_exported?(socket.view, :plugins_changed, 2),
        do: socket.view.plugins_changed(socket, event),
        else: socket

    {:halt, socket}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # [] when the registry isn't there (it never breaks the bar)
  defp active_plugins do
    Beamdash.Plugins.active()
  catch
    :exit, _ -> []
  end

  defp refresh(%{assigns: %{conn: %{status: :connected}}} = socket) do
    case Target.node_info() do
      {:ok, info} -> update(socket, info: info)
      {:error, _} -> socket
    end
  end

  defp refresh(%{assigns: %{conn: %{status: :disconnected}}} = socket),
    do: update(socket, reconnecting: Target.reconnecting())

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

  # All kubectl calls run in the task, since a pod or container can be slow to answer.
  defp restore_kube(cluster, namespace, saved) do
    with {:ok, pods} <- Kubectl.list_pods(cluster, namespace) do
      if pods == [] do
        {:ok, %{pods: []}}
      else
        same_namespace = saved["cluster"] == cluster and saved["namespace"] == namespace
        pod = if same_namespace and saved["pod"] in pods, do: saved["pod"], else: List.first(pods)

        case Kubectl.list_containers(cluster, namespace, pod) do
          {:error, reason} ->
            {:partial, %{pods: pods, pod: pod, error: reason}}

          {:ok, containers} ->
            same_pod = same_namespace and saved["pod"] == pod

            container =
              if same_pod and saved["container"] in containers,
                do: saved["container"],
                else: List.first(containers)

            case Kubectl.list_binaries(cluster, namespace, pod, container) do
              {:error, reason} ->
                {:partial,
                 %{
                   pods: pods,
                   pod: pod,
                   containers: containers,
                   container: container,
                   error: reason
                 }}

              {:ok, binaries} ->
                binary =
                  if same_pod and saved["container"] == container and saved["binary"] in binaries,
                    do: saved["binary"],
                    else: List.first(binaries)

                {:ok,
                 %{
                   pods: pods,
                   pod: pod,
                   containers: containers,
                   container: container,
                   binaries: binaries,
                   binary: binary
                 }}
            end
        end
      end
    end
  end

  # Lists `pod`'s containers and then the release binaries in the first one, storing
  # `pod` itself (shared by the initial pod listing and picking a different
  # pod from the dropdown).
  defp list_containers(socket, cluster, namespace, pod) do
    socket = update(socket, kube_pod: pod, kube_listing: true)

    case Kubectl.list_containers(cluster, namespace, pod) do
      {:ok, containers} ->
        saved = Settings.kube_selection()

        container =
          if saved["cluster"] == cluster and saved["namespace"] == namespace and
               saved["pod"] == pod and saved["container"] in containers,
             do: saved["container"],
             else: List.first(containers)

        list_binaries(socket, cluster, namespace, pod, container, containers)

      {:error, reason} ->
        update(socket, error: Format.error(reason), kube_listing: false)
    end
  end

  # Lists the release binaries in `container` and fills `kube_binaries`/`kube_binary`,
  # also storing the full container list and the one picked (shared by
  # `list_containers/4` and "select_kube_container").
  defp list_binaries(socket, cluster, namespace, pod, container, containers) do
    socket = update(socket, kube_containers: containers, kube_container: container)

    case Kubectl.list_binaries(cluster, namespace, pod, container) do
      {:ok, binaries} ->
        saved = Settings.kube_selection()

        binary =
          if saved["cluster"] == cluster and saved["namespace"] == namespace and
               saved["pod"] == pod and saved["container"] == container and
               saved["binary"] in binaries, do: saved["binary"], else: List.first(binaries)

        socket =
          update(socket,
            kube_binaries: binaries,
            kube_binary: binary,
            kube_listing: false
          )

        save_kube_selection(socket, binary)
        socket

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

  defp save_kube_selection(socket, binary) do
    conn = socket.assigns.conn

    Settings.put_kube_selection(%{
      "cluster" => conn.kube_cluster,
      "namespace" => conn.kube_namespace,
      "pod" => conn.kube_pod,
      "container" => conn.kube_container,
      "binary" => binary
    })
  end

  @doc "Forgets a node typed in this session that did not connect."
  def forget_typed do
    :persistent_term.erase(@last_node)
    :ok
  end

  defp last_node(saved), do: :persistent_term.get(@last_node, saved)
end
