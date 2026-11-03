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

  `@conn.connecting` and `@conn.kube_progress` are the step a kubectl connect
  or a pod listing is on (label, command, elapsed seconds), shown in the bar
  while it runs.

  The form starts with the last node and cookie that connected
  (`Beamdash.LastConnection`, kept across restarts); a node typed in this
  session that failed to connect is offered instead until one succeeds.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_navigate: 2]

  alias Beamdash.{Format, Kubectl, LastConnection, Settings, Target}

  @refresh_ms 2_000
  @last_node {__MODULE__, :last_node}
  # the last kubectl listings (namespaces, a restored selection), so the
  # bar of each page mounted soon after fills without running kubectl again
  @kube_cache {__MODULE__, :kube_cache}
  @kube_cache_ms 60_000
  @progress_ms 1_000

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
          method: Settings.connection_method(),
          kube_cluster: cluster,
          kube_namespace:
            if(cluster == kube_saved["cluster"], do: kube_saved["namespace"], else: ""),
          kube_namespaces: [],
          kube_pod: "",
          kube_pods: nil,
          kube_pods_listing: false,
          kube_target:
            if(status == :connected, do: kube_target(Target.source(), clusters.kube_clusters)),
          kube_restore_ref: nil,
          kube_containers: nil,
          kube_container: nil,
          kube_binaries: nil,
          kube_binary: nil,
          connecting: nil,
          kube_progress: nil,
          progress_timer: false,
          reconnecting: if(status == :connected, do: nil, else: Target.reconnecting()),
          plugins: active_plugins()
        })
      )
      |> attach_hook(:conn_event, :handle_event, &handle_event/3)
      |> attach_hook(:conn_info, :handle_info, &handle_info/2)

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = Target.subscribe_connecting()
      :ok = Phoenix.PubSub.subscribe(Beamdash.PubSub, "plugins")
      send(self(), :beamdash_conn_tick)

      if socket.assigns.conn.method == :kubectl and status != :connected,
        do: send(self(), :beamdash_restore_saved_kube)
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
           cookie_input: cookie,
           kube_target: nil
         )
         |> to_system()}

      {:error, reason} ->
        {:halt,
         update(socket, error: Format.error(reason), node_input: node, cookie_input: cookie)}
    end
  end

  def handle_event("disconnect", _params, socket) do
    :ok = Target.disconnect()

    {:halt,
     socket
     |> update(
       status: :disconnected,
       node: nil,
       info: nil,
       kube_target: nil,
       reconnecting: nil,
       connecting: nil
     )
     |> to_root()}
  end

  def handle_event("stop_reconnect", _params, socket) do
    :ok = Target.stop_reconnect()
    {:halt, update(socket, reconnecting: nil)}
  end

  # namespaces are re-listed each time Kubernetes is picked from another
  # method, so ones created meanwhile show up too
  def handle_event("set_conn_method", %{"method" => method}, socket) do
    case method do
      "direct" -> {:halt, select_conn_method(socket, :direct)}
      "kubectl" -> {:halt, select_conn_method(socket, :kubectl)}
      _ -> {:halt, socket}
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
        kube_pods: nil,
        kube_pod: "",
        kube_containers: nil,
        kube_container: nil,
        kube_binaries: nil,
        kube_binary: nil,
        error: nil
      )

    {:halt, start_kube_listing(socket, cluster, namespace, :pods, saved)}
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
        kube_pod: pod,
        kube_containers: nil,
        kube_container: nil,
        kube_binaries: nil,
        kube_binary: nil,
        error: nil
      )

    {:halt,
     start_kube_listing(
       socket,
       socket.assigns.conn.kube_cluster,
       namespace,
       {:pod, pod},
       Settings.kube_selection()
     )}
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

    socket =
      update(socket, kube_container: container, kube_binaries: nil, kube_binary: nil, error: nil)

    {:halt,
     start_kube_listing(
       socket,
       socket.assigns.conn.kube_cluster,
       namespace,
       {:container, pod, socket.assigns.conn.kube_containers, container},
       Settings.kube_selection()
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
    if socket.assigns.conn.connecting do
      {:halt, socket}
    else
      namespace = String.trim(namespace)
      pod = socket.assigns.conn.kube_pod
      container = String.trim(container)
      cluster = socket.assigns.conn.kube_cluster
      save_kube_selection(socket, binary)

      ctx = %{
        cluster: cluster,
        namespace: namespace,
        pod: pod,
        container: container,
        binary: binary
      }

      pid = self()

      {:ok, _} =
        Task.start(fn -> send(pid, {:beamdash_kube_connected, ctx, connect_kubectl(ctx)}) end)

      {:halt, put_progress(socket, :connecting, progress_step("Connecting…", nil))}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  @doc false
  def handle_info(
        :beamdash_restore_saved_kube,
        %{assigns: %{conn: %{method: :kubectl, status: :disconnected}}} = socket
      ),
      do: {:halt, restore_saved_kube(socket)}

  def handle_info(:beamdash_restore_saved_kube, socket), do: {:halt, socket}

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
         reconnecting: nil,
         kube_target:
           kube_target(Target.source(), Map.get(socket.assigns.conn, :kube_clusters, []))
       )
       |> refresh()}

  def handle_info({:beamdash_target, {:disconnected, reason}}, socket) do
    error = if reason == :nodedown, do: "Lost the connection to #{socket.assigns.conn.node}."

    {:cont,
     socket
     |> update(
       status: :disconnected,
       node: nil,
       info: nil,
       kube_target: nil,
       error: error,
       reconnecting: Target.reconnecting()
     )
     |> then(fn s -> if reason == :reconnect, do: s, else: to_root(s) end)}
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
          {:ok, names} -> kube_cache_put({:namespaces, cluster}, names)
          {:error, _} -> []
        end

      {:halt, update(socket, kube_namespaces: namespaces)}
    else
      {:halt, socket}
    end
  end

  def handle_info({:beamdash_kube_listed, ref, cluster, namespace, result}, socket) do
    if socket.assigns.conn.kube_restore_ref == ref do
      case result do
        {status, %{} = listed} when status in [:ok, :partial] ->
          if status == :ok and Map.has_key?(listed, :pods),
            do: kube_cache_put({:restore, cluster, namespace, Settings.kube_selection()}, listed)

          socket = apply_listed(socket, status, listed)
          if status == :ok and listed[:pod], do: save_kube_selection(socket, listed[:binary])
          {:halt, socket}

        {:error, reason} ->
          {:halt,
           update(socket,
             kube_pods_listing: false,
             kube_restore_ref: nil,
             kube_progress: nil,
             error: Format.error(reason)
           )}
      end
    else
      {:halt, socket}
    end
  end

  def handle_info({:beamdash_kube_progress, ref, label, command}, socket) do
    if socket.assigns.conn.kube_restore_ref == ref,
      do: {:halt, put_progress(socket, :kube_progress, progress_step(label, command))},
      else: {:halt, socket}
  end

  def handle_info({:beamdash_kube_connected, ctx, result}, socket) do
    case result do
      {:error, :cancelled} ->
        {:halt, update(socket, connecting: nil)}

      {:ok, info} ->
        # the page hears {:connected, node} from Target as well
        {:halt,
         socket
         |> update(
           status: :connected,
           node: info.node,
           info: info,
           error: nil,
           connecting: nil,
           kube_namespace: ctx.namespace,
           kube_pod: ctx.pod,
           kube_container: ctx.container,
           kube_binary: ctx.binary,
           kube_target:
             kube_target(
               {:kubectl, %{kubeconfig: ctx.cluster, namespace: ctx.namespace, pod: ctx.pod}},
               socket.assigns.conn.kube_clusters
             )
         )
         |> to_system()}

      {:error, reason} ->
        {:halt,
         update(socket,
           error: Format.error(reason),
           connecting: nil,
           kube_namespace: ctx.namespace,
           kube_pod: ctx.pod,
           kube_container: ctx.container,
           kube_binary: ctx.binary
         )}
    end
  end

  def handle_info({:beamdash_connecting, step}, socket) do
    step = if step, do: progress_step(step.label, step.command)
    {:halt, put_progress(socket, :connecting, step)}
  end

  def handle_info(:beamdash_progress_tick, socket) do
    socket =
      socket
      |> tick_progress(:connecting)
      |> tick_progress(:kube_progress)

    if active_progress?(socket) do
      Process.send_after(self(), :beamdash_progress_tick, @progress_ms)
      {:halt, socket}
    else
      {:halt, update(socket, progress_timer: false)}
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

  @doc false
  def kube_target({:kubectl, %{kubeconfig: kubeconfig, namespace: namespace, pod: pod}}, clusters)
      when is_binary(kubeconfig) do
    default = Path.rootname(Path.basename(kubeconfig))

    name =
      Enum.find_value(clusters, default, fn entry ->
        entry.path == kubeconfig && entry.name
      end)

    %{cluster: name, namespace: namespace, pod: pod}
  end

  def kube_target(_source, _clusters), do: nil

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

  # A listing from the last @kube_cache_ms, or :none. (persistent_term:
  # written only when kubectl answers, read by every page's bar.)
  defp kube_cache_get(key) do
    case :persistent_term.get(@kube_cache, %{}) do
      %{^key => {at, value}} ->
        if System.monotonic_time(:millisecond) - at < @kube_cache_ms,
          do: {:ok, value},
          else: :none

      _ ->
        :none
    end
  end

  defp kube_cache_put(key, value) do
    cache = :persistent_term.get(@kube_cache, %{})

    :persistent_term.put(
      @kube_cache,
      Map.put(cache, key, {System.monotonic_time(:millisecond), value})
    )

    value
  end

  @doc false
  def forget_kube_cache, do: :persistent_term.erase(@kube_cache)

  defp select_conn_method(socket, method) do
    :ok = Settings.put_connection_method(method)
    switched? = socket.assigns.conn[:method] != method
    socket = update(socket, method: method, error: nil)

    socket =
      if switched?,
        do: update(socket, kube_restore_ref: nil, kube_pods_listing: false),
        else: socket

    if method == :kubectl and switched?,
      do: restore_saved_kube(socket),
      else: socket
  end

  # From the cache when kubectl answered in the last minute (another
  # page's bar), else in the background.
  defp restore_saved_kube(socket) do
    cluster = socket.assigns.conn.kube_cluster
    namespace = Map.get(socket.assigns.conn, :kube_namespace, "")

    socket =
      case cluster && kube_cache_get({:namespaces, cluster}) do
        {:ok, names} -> update(socket, kube_namespaces: names)
        _ -> list_namespaces(socket)
      end

    case cluster && is_nil(socket.assigns.conn[:kube_pods]) &&
           kube_cache_get({:restore, cluster, namespace, Settings.kube_selection()}) do
      {:ok, restored} -> apply_listed(socket, :ok, restored)
      _ -> restore_saved_kube_listing(socket)
    end
  end

  defp restore_saved_kube_listing(socket) do
    if socket.assigns.conn.kube_cluster &&
         Map.get(socket.assigns.conn, :kube_namespace, "") != "" &&
         is_nil(socket.assigns.conn[:kube_pods]) do
      start_kube_listing(
        socket,
        socket.assigns.conn.kube_cluster,
        socket.assigns.conn.kube_namespace,
        :pods,
        Settings.kube_selection()
      )
      |> update(kube_pods_listing: true)
    else
      socket
    end
  end

  # The listing runs in a task, since a pod or container can be slow to answer.
  # Its steps report what they run as `{:beamdash_kube_progress, ref, label, command}`
  # and the result comes back as `{:beamdash_kube_listed, ref, cluster, namespace, result}`;
  # a result for a ref no longer current is dropped.
  defp start_kube_listing(socket, cluster, namespace, stage, saved) do
    ref = make_ref()
    pid = self()
    report = fn label, command -> send(pid, {:beamdash_kube_progress, ref, label, command}) end

    {:ok, _} =
      Task.start(fn ->
        listed = kube_listing(cluster, namespace, stage, saved, report)
        send(pid, {:beamdash_kube_listed, ref, cluster, namespace, listed})
      end)

    update(socket, kube_restore_ref: ref)
  end

  defp kube_listing(cluster, namespace, :pods, saved, report) do
    case Kubectl.list_pods(cluster, namespace, reported(report, "Listing pods in #{namespace}")) do
      {:ok, []} ->
        {:ok, %{pods: []}}

      {:ok, pods} ->
        same_namespace = saved["cluster"] == cluster and saved["namespace"] == namespace
        pod = if same_namespace and saved["pod"] in pods, do: saved["pod"], else: List.first(pods)
        container_listing(cluster, namespace, pod, %{pods: pods}, saved, report)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp kube_listing(cluster, namespace, {:pod, pod}, saved, report),
    do: container_listing(cluster, namespace, pod, %{}, saved, report)

  defp kube_listing(cluster, namespace, {:container, pod, containers, container}, saved, report) do
    listed = %{pod: pod, containers: containers, container: container}
    binary_listing(cluster, namespace, pod, container, listed, saved, report)
  end

  defp container_listing(cluster, namespace, pod, listed, saved, report) do
    case Kubectl.list_containers(
           cluster,
           namespace,
           pod,
           reported(report, "Listing containers of #{pod}")
         ) do
      {:ok, containers} ->
        same_pod =
          saved["cluster"] == cluster and saved["namespace"] == namespace and saved["pod"] == pod

        container =
          if same_pod and saved["container"] in containers,
            do: saved["container"],
            else: List.first(containers)

        listed = Map.merge(listed, %{pod: pod, containers: containers, container: container})
        binary_listing(cluster, namespace, pod, container, listed, saved, report)

      {:error, reason} ->
        {:partial, Map.merge(listed, %{pod: pod, error: reason})}
    end
  end

  defp binary_listing(cluster, namespace, pod, container, listed, saved, report) do
    label = "Listing release binaries in #{container}"

    case Kubectl.list_binaries(cluster, namespace, pod, container, reported(report, label)) do
      {:ok, binaries} ->
        same_container =
          saved["cluster"] == cluster and saved["namespace"] == namespace and
            saved["pod"] == pod and saved["container"] == container

        binary =
          if same_container and saved["binary"] in binaries,
            do: saved["binary"],
            else: List.first(binaries)

        {:ok, Map.merge(listed, %{binaries: binaries, binary: binary})}

      {:error, reason} ->
        {:partial, Map.put(listed, :error, reason)}
    end
  end

  defp reported(report, label) do
    fn args ->
      report.(label, Kubectl.command_line(args))
      Kubectl.run_kubectl(args)
    end
  end

  defp apply_listed(socket, status, listed) do
    fields =
      listed
      |> Map.take([:pods, :pod, :containers, :container, :binaries, :binary])
      |> Map.new(fn {key, value} -> {:"kube_#{key}", value} end)

    update(
      socket,
      Map.merge(fields, %{
        kube_pods_listing: false,
        kube_restore_ref: nil,
        kube_progress: nil,
        error: if(status == :partial, do: Format.error(listed.error))
      })
    )
  end

  defp connect_kubectl(ctx) do
    Target.connect_via_kubectl(ctx.cluster, ctx.namespace, ctx.pod, ctx.container, ctx.binary)
  catch
    :exit, reason -> {:error, {:connect_failed, reason}}
  end

  # One tick chain at a time: it runs while any progress is active and clears
  # `progress_timer` when it stops, so a step set later starts a new chain.
  defp put_progress(socket, key, step) do
    socket = update(socket, [{key, step}])

    if step && !socket.assigns.conn.progress_timer do
      Process.send_after(self(), :beamdash_progress_tick, @progress_ms)
      update(socket, progress_timer: true)
    else
      socket
    end
  end

  defp progress_step(label, command),
    do: %{label: label, command: command, since: System.monotonic_time(:millisecond), elapsed: 0}

  defp active_progress?(socket),
    do: Enum.any?([:connecting, :kube_progress], fn key -> socket.assigns.conn[key] end)

  defp tick_progress(socket, key) do
    case socket.assigns.conn[key] do
      nil ->
        socket

      step ->
        elapsed = div(System.monotonic_time(:millisecond) - step.since, 1000)
        update(socket, [{key, %{step | elapsed: elapsed}}])
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

  defp to_root(%{view: BeamdashWeb.HomeLive} = socket), do: socket
  defp to_root(socket), do: push_navigate(socket, to: "/")

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
