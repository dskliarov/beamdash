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
  while it runs. `@conn.connecting_others` maps the server of each other
  connection that is connecting to its step, one bar line each.

  The bar lists the saved connections (`Beamdash.LastConnection`, kept across
  restarts). Clicking one connects it, and each can be deleted. The form
  starts with the first saved node and cookie; a node typed in this session
  that failed to connect is offered instead until one succeeds.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_navigate: 2, redirect: 2]

  alias Beamdash.{Connections, Format, Kubectl, LastConnection, Settings, Target}

  @refresh_ms 2_000
  @last_node {__MODULE__, :last_node}
  @only_selected {__MODULE__, :only_selected}
  # the last kubectl listings (namespaces, a restored selection), so the
  # bar of each page mounted soon after fills without running kubectl again
  @kube_cache {__MODULE__, :kube_cache}
  @kube_cache_ms 60_000
  @progress_ms 1_000

  def on_mount(:default, _params, session, socket) do
    selected = session["selected_node"]
    {server, status, node} = choose(selected)
    saved = LastConnection.list()
    direct = Enum.find(saved, &(&1["kind"] == "node")) || %{}
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
          server: server,
          selected_node: selected,
          status: status,
          node: node,
          connections: listed(clusters.kube_clusters),
          info: nil,
          node_input: if(node, do: Atom.to_string(node), else: last_node(direct["node"] || "")),
          cookie_input: direct["cookie"] || "",
          saved: saved,
          error: nil,
          method: Settings.connection_method(),
          multiple: Settings.multiple_connections?(),
          panel: false,
          only_selected: :persistent_term.get(@only_selected, false),
          kube_cluster: cluster,
          kube_namespace:
            if(cluster == kube_saved["cluster"], do: kube_saved["namespace"], else: ""),
          kube_namespaces: [],
          kube_pod: "",
          kube_pods: nil,
          kube_pods_listing: false,
          kube_target:
            if(status == :connected,
              do: kube_target(Target.source(server), clusters.kube_clusters)
            ),
          kube_restore_ref: nil,
          kube_containers: nil,
          kube_container: nil,
          kube_binaries: nil,
          kube_binary: nil,
          connecting: nil,
          connecting_others: %{},
          kube_progress: nil,
          progress_timer: false,
          reconnecting: if(status == :connected, do: nil, else: Target.reconnecting(server)),
          plugins: active_plugins()
        })
      )
      |> attach_hook(:conn_event, :handle_event, &handle_event/3)
      |> attach_hook(:conn_info, :handle_info, &handle_info/2)

    if connected?(socket) do
      subscribe_all()
      :ok = Connections.subscribe()
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

    case Connections.find_node(node) do
      %{node: existing} ->
        {:halt,
         socket
         |> to_node(existing)
         |> update(notice: "#{existing} is already connected, so it is selected.")}

      nil ->
        identity = {:direct, Connections.node_app(node)}

        case if(node == "", do: :ok, else: Connections.check_application(identity, node)) do
          :ok ->
            connect_direct(socket, node, cookie, identity)

          {:error, reason} ->
            {:halt,
             update(socket, error: Format.error(reason), node_input: node, cookie_input: cookie)}
        end
    end
  end

  def handle_event("disconnect", params, socket) do
    case disconnect_server(socket, params) do
      nil ->
        {:halt, socket}

      server ->
        own? = server == socket.assigns.conn.server
        :ok = Connections.remove(server)

        socket = socket |> resolve() |> then(&if(own?, do: update(&1, connecting: nil), else: &1))
        {:halt, if(socket.assigns.conn.status == :connected, do: socket, else: to_root(socket))}
    end
  end

  def handle_event("disconnect_all", _params, socket) do
    for %{server: server} <- Connections.list(), do: :ok = Connections.remove(server)

    socket = socket |> resolve() |> update(connecting: nil)
    {:halt, to_root(socket)}
  end

  def handle_event("stop_reconnect", _params, socket) do
    :ok = Target.stop_reconnect(socket.assigns.conn.server)
    {:halt, update(socket, reconnecting: nil)}
  end

  def handle_event("toggle_panel", _params, socket) do
    {:halt, update(socket, panel: not socket.assigns.conn[:panel])}
  end

  def handle_event("toggle_only_selected", _params, socket) do
    only_selected = not socket.assigns.conn[:only_selected]
    :persistent_term.put(@only_selected, only_selected)
    {:halt, update(socket, only_selected: only_selected)}
  end

  # namespaces are re-listed each time Kubernetes is picked from another
  # method, so ones created meanwhile show up too
  def handle_event("set_conn_method", %{"method" => method}, socket) do
    case method do
      "direct" -> {:halt, select_conn_method(socket, :direct)}
      "kubectl" -> {:halt, select_conn_method(socket, :kubectl)}
      "saved" -> {:halt, select_conn_method(socket, :saved)}
      _ -> {:halt, socket}
    end
  end

  def handle_event(
        "select_kube_cluster",
        _params,
        %{assigns: %{conn: %{connecting: connecting}}} = socket
      )
      when connecting != nil,
      do: {:halt, socket}

  # picking a different cluster invalidates everything listed under the old
  # one, same reset `"select_kube_pod"` does for a different pod.
  def handle_event("select_kube_cluster", %{"cluster" => cluster}, socket) do
    if Enum.any?(Map.get(socket.assigns.conn, :kube_clusters, []), &(&1.path == cluster)) do
      Settings.put_kube_selection(%{"cluster" => cluster})

      {:halt,
       socket
       |> update(
         kube_cluster: cluster,
         kube_progress: nil,
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
    else
      {:halt, socket}
    end
  end

  def handle_event(
        "list_kube_pods",
        _params,
        %{assigns: %{conn: %{connecting: connecting}}} = socket
      )
      when connecting != nil,
      do: {:halt, socket}

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
    if container in (Map.get(socket.assigns.conn, :kube_containers) || []) do
      namespace = String.trim(namespace)
      pod = String.trim(pod)

      Settings.put_kube_selection(%{
        "cluster" => socket.assigns.conn.kube_cluster,
        "namespace" => namespace,
        "pod" => pod,
        "container" => container
      })

      socket =
        update(socket,
          kube_container: container,
          kube_binaries: nil,
          kube_binary: nil,
          error: nil
        )

      {:halt,
       start_kube_listing(
         socket,
         socket.assigns.conn.kube_cluster,
         namespace,
         {:container, pod, socket.assigns.conn.kube_containers, container},
         Settings.kube_selection()
       )}
    else
      {:halt, socket}
    end
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
    container = String.trim(container)
    listed = ["" | Map.get(socket.assigns.conn, :kube_containers) || []]

    if socket.assigns.conn.connecting || container not in listed do
      {:halt, socket}
    else
      namespace = String.trim(namespace)
      pod = socket.assigns.conn.kube_pod
      cluster = socket.assigns.conn.kube_cluster
      save_kube_selection(socket, binary)

      ctx = %{
        cluster: cluster,
        namespace: namespace,
        pod: pod,
        container: container,
        binary: binary,
        server: Connections.target_for_connect()
      }

      pid = self()

      {:ok, _} =
        Task.start(fn -> send(pid, {:beamdash_kube_connected, ctx, connect_kubectl(ctx)}) end)

      {:halt, put_progress(socket, :connecting, progress_step("Connecting…", nil))}
    end
  end

  def handle_event("forget_saved", %{"id" => id}, socket) do
    LastConnection.delete(id)
    {:halt, update(socket, saved: LastConnection.list())}
  end

  def handle_event("connect_saved", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.conn.saved, &(&1["id"] == id)) do
      %{"kind" => "node"} = entry ->
        handle_event("connect", %{"node" => entry["node"], "cookie" => entry["cookie"]}, socket)

      %{} = entry ->
        {:halt, connect_saved_kube(socket, entry)}

      _ ->
        {:halt, socket}
    end
  end

  def handle_event("saved_selection", params, socket) do
    {:halt, update(socket, selected: Map.get(params, "ids", []))}
  end

  def handle_event("connect_saved_many", params, socket) do
    conn = socket.assigns.conn
    ids = Map.get(params, "ids", [])
    connected = Enum.map(Connections.connected(), &to_string(&1.node))
    entries = Enum.filter(conn.saved, &(&1["id"] in ids and &1["node"] not in connected))

    cond do
      conn.connecting != nil ->
        {:halt, socket}

      not conn.multiple ->
        {:halt,
         update(socket,
           error: "Turn on Allow multiple connections in Settings to connect several at once."
         )}

      entries == [] ->
        {:halt, update(socket, error: "Check the saved connections that are not connected yet.")}

      true ->
        case check_batch(entries) do
          :ok -> {:halt, start_batch(socket, entries)}
          {:error, message} -> {:halt, update(socket, error: message)}
        end
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

  # The event does not say which connection it is about, so the bar is
  # worked out again from the connections.
  def handle_info({:beamdash_target, {:connected, _node}}, socket) do
    socket = socket |> resolve() |> update(error: nil)
    {:cont, refresh(socket)}
  end

  def handle_info({:beamdash_target, {:disconnected, reason}}, socket) do
    lost = socket.assigns.conn.node
    error = if reason == :nodedown, do: "Lost the connection to #{lost}."
    Connections.prune()
    socket = socket |> resolve() |> update(error: error)

    socket =
      if socket.assigns.conn.status == :connected or reason == :reconnect,
        do: socket,
        else: to_root(socket)

    {:cont, socket}
  end

  def handle_info({:beamdash_connections, :changed}, socket) do
    subscribe_all()
    {:halt, resolve(socket)}
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
        kube_progress: nil,
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
      |> then(&update(&1, connections: listed(&1.assigns.conn.kube_clusters)))

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

  def handle_info({:beamdash_kube_event, ref, event}, socket) do
    if socket.assigns.conn.kube_restore_ref == ref,
      do: {:halt, kube_event(socket, event)},
      else: {:halt, socket}
  end

  def handle_info({:beamdash_kube_connected, ctx, result}, socket) do
    if match?({:error, _}, result), do: Connections.discard(ctx.server)

    case result do
      {:error, :cancelled} ->
        {:halt, update(socket, connecting: nil)}

      {:ok, info} ->
        save_kube_connection(ctx, info)
        Connections.broadcast()

        {:halt,
         socket
         |> update(
           error: nil,
           connecting: nil,
           kube_namespace: ctx.namespace,
           kube_pod: ctx.pod,
           kube_container: ctx.container,
           kube_binary: ctx.binary,
           saved: LastConnection.list()
         )
         |> to_system(info.node)}

      {:error, {:saved_pod_unavailable, reason}} ->
        {:halt, saved_pod_unavailable(socket, ctx, reason)}

      {:error, {:already_connected, node}} ->
        socket =
          case Connections.find_node(Atom.to_string(node)) do
            %{node: existing} ->
              socket
              |> to_node(existing)
              |> update(notice: "#{existing} is already connected, so it is selected.")

            nil ->
              update(socket, error: "#{node} is already connected.")
          end

        {:halt, update(socket, connecting: nil)}

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

  def handle_info({:beamdash_connecting, server, step}, socket) do
    step = if step, do: progress_step(step.label, step.command)

    socket =
      if own_server?(socket, server),
        do: put_progress(socket, :connecting, step),
        else: put_other_progress(socket, server, step)

    {:halt, socket}
  end

  def handle_info(:beamdash_progress_tick, socket) do
    socket =
      socket
      |> tick_progress(:connecting)
      |> tick_progress(:kube_progress)
      |> tick_other_progress()

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

  def handle_info({:beamdash_saved_many, results}, socket) do
    {ok, failed} =
      Enum.split_with(results, fn {_entry, _server, result} -> match?({:ok, _}, result) end)

    for {entry, server, {:ok, info}} <- ok do
      Connections.record_application(server, batch_identity(entry))
      save_batch_entry(entry, server, info)
    end

    for {_entry, server, _result} <- failed, do: Connections.discard(server)
    Connections.broadcast()

    socket =
      socket
      |> update(connecting: nil, saved: LastConnection.list())
      |> resolve()

    case {ok, failed} do
      {[{_, _, {:ok, info}} | _], []} -> {:halt, to_system(socket, info.node)}
      _ -> {:halt, update(socket, error: batch_message(ok, failed))}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # One application per batch. A kubectl entry whose application is not known
  # yet is connected on its own, since two unknown ones could be different.
  defp check_batch([first | _] = entries) do
    identity = batch_identity(first)

    cond do
      Enum.any?(entries, &(batch_identity(&1) != identity)) ->
        {:error,
         "The checked connections run different applications. Connect each one on its own."}

      length(entries) > 1 and identity == {:kubectl, ""} ->
        {:error, "A saved connection of unknown application is connected on its own."}

      true ->
        case Connections.check_application(identity, batch_label(first)) do
          :ok -> :ok
          {:error, reason} -> {:error, Format.error(reason)}
        end
    end
  end

  defp start_batch(socket, entries) do
    pid = self()
    work = Enum.zip(entries, Connections.targets_for_connect(length(entries)))

    {:ok, _} =
      Task.start(fn ->
        results =
          work
          |> Task.async_stream(
            fn {entry, server} -> {entry, server, connect_batch_entry(entry, server)} end,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, result} -> result end)

        send(pid, {:beamdash_saved_many, results})
      end)

    socket
    |> update(error: nil, notice: nil)
    |> put_progress(:connecting, progress_step("Connecting #{length(entries)} connections…", nil))
  end

  defp connect_batch_entry(%{"kind" => "node"} = entry, server) do
    cookie = if(entry["cookie"] in [nil, ""], do: nil, else: entry["cookie"])
    Target.connect(entry["node"], cookie, server)
  catch
    :exit, reason -> {:error, {:connect_failed, reason}}
  end

  defp connect_batch_entry(entry, server), do: Target.connect_saved_kubectl(entry, server)

  defp batch_identity(%{"kind" => "node", "node" => node}),
    do: {:direct, Connections.node_app(node)}

  defp batch_identity(entry), do: {:kubectl, entry["app"] || ""}

  defp batch_label(%{"kind" => "node", "node" => node}), do: node
  defp batch_label(entry), do: entry["pod"]

  defp save_batch_entry(%{"kind" => "node"} = entry, _server, _info) do
    LastConnection.put(%{
      "kind" => "node",
      "node" => entry["node"],
      "cookie" => entry["cookie"] || ""
    })
  end

  # connect_batch_entry sets no identity on the result, so it is built from the entry
  defp save_batch_entry(entry, server, info) do
    ctx = %{
      cluster: entry["kubeconfig"],
      namespace: entry["namespace"],
      pod: entry["pod"],
      container: entry["container"],
      binary: entry["binary"],
      server: server
    }

    save_kube_connection(ctx, %{node: info.node, identity: batch_identity(entry)})
  end

  defp batch_message(ok, failed) do
    failures =
      Enum.map_join(failed, "; ", fn {entry, _server, {:error, reason}} ->
        "#{batch_label(entry)}: #{Format.error(reason)}"
      end)

    if ok == [],
      do: failures,
      else: "Connected #{length(ok)} of #{length(ok) + length(failed)}. #{failures}"
  end

  # The session's node when it is still connected, else the first connected
  # node, else the default target, disconnected.
  defp choose(selected) do
    connected = Connections.connected()

    case Enum.find(connected, &(Atom.to_string(&1.node) == selected)) || List.first(connected) do
      nil -> {Target, :disconnected, nil}
      %{server: server, node: node} -> {server, :connected, node}
    end
  end

  defp resolve(socket) do
    conn = socket.assigns.conn
    {server, status, node} = choose(conn.selected_node)

    update(socket,
      server: server,
      status: status,
      node: node,
      info: if(status == :connected and node == conn.node, do: conn.info),
      connections: listed(conn.kube_clusters),
      kube_target:
        if(status == :connected,
          do: kube_target(Target.source(server), conn.kube_clusters)
        ),
      reconnecting: if(status == :connected, do: nil, else: Target.reconnecting(server))
    )
  end

  defp disconnect_server(_socket, %{"server" => key}) do
    case Connections.find_key(key) do
      %{server: server} -> server
      nil -> nil
    end
  end

  defp disconnect_server(socket, %{"node" => node}) do
    case Enum.find(Map.get(socket.assigns.conn, :connections, []), &(to_string(&1.node) == node)) do
      %{server: server} -> server
      nil -> socket.assigns.conn.server
    end
  end

  defp disconnect_server(socket, _params), do: socket.assigns.conn.server

  defp subscribe_all do
    Enum.each(Connections.list(), fn %{server: server} -> :ok = Target.subscribe(server) end)
  end

  # [] when the registry isn't there (it never breaks the bar)
  defp active_plugins do
    Beamdash.Plugins.active()
  catch
    :exit, _ -> []
  end

  defp listed(clusters) do
    for entry <- Connections.list() do
      kube =
        if entry.status == :connected,
          do: kube_target(Target.source(entry.server), clusters)

      Map.put(entry, :kube_target, kube)
    end
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

  defp refresh(%{assigns: %{conn: %{status: :connected} = conn}} = socket) do
    case Target.node_info(conn.server) do
      {:ok, info} -> update(socket, info: info)
      {:error, _} -> socket
    end
  end

  defp refresh(%{assigns: %{conn: %{status: :disconnected} = conn}} = socket),
    do: update(socket, reconnecting: Target.reconnecting(conn.server))

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
        do: update(socket, kube_restore_ref: nil, kube_pods_listing: false, kube_progress: nil),
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
  # Its steps and the pod names, once listed, come back as
  # `{:beamdash_kube_event, ref, event}`, and the result as
  # `{:beamdash_kube_listed, ref, cluster, namespace, result}`; anything for a
  # ref no longer current is dropped.
  defp start_kube_listing(socket, cluster, namespace, stage, saved) do
    ref = make_ref()
    pid = self()
    report = fn event -> send(pid, {:beamdash_kube_event, ref, event}) end

    {:ok, _} =
      Task.start(fn ->
        listed = kube_listing(cluster, namespace, stage, saved, report)
        send(pid, {:beamdash_kube_listed, ref, cluster, namespace, listed})
      end)

    update(socket, kube_restore_ref: ref)
  end

  defp kube_event(socket, {:progress, label, command}),
    do: put_progress(socket, :kube_progress, progress_step(label, command))

  defp kube_event(socket, {:pods, pods}), do: update(socket, kube_pods: pods)

  defp kube_listing(cluster, namespace, :pods, saved, report) do
    case Kubectl.list_pods(cluster, namespace, reported(report, "Listing pods in #{namespace}")) do
      {:ok, []} ->
        {:ok, %{pods: []}}

      {:ok, pods} ->
        report.({:pods, pods})
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
      report.({:progress, label, Kubectl.command_line(args)})
      Kubectl.run_kubectl(args)
    end
  end

  defp apply_listed(socket, status, listed) do
    fields =
      %{pod: nil, containers: [], container: nil, binaries: [], binary: nil}
      |> Map.merge(listed)
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

  defp connect_direct(socket, node, cookie, identity) do
    server = Connections.target_for_connect()

    case Target.connect(node, if(cookie == "", do: nil, else: cookie), server) do
      {:ok, info} ->
        Connections.record_application(server, identity)
        # remembered for the form, also after a restart
        LastConnection.put(%{"kind" => "node", "node" => node, "cookie" => cookie})
        :persistent_term.erase(@last_node)
        Connections.broadcast()

        {:halt,
         socket
         |> update(
           error: nil,
           notice: nil,
           cookie_input: cookie,
           saved: LastConnection.list(),
           node_input: node,
           selected_node: Atom.to_string(info.node)
         )
         |> resolve()
         |> refresh()
         |> to_system(info.node)}

      {:error, reason} ->
        Connections.discard(server)

        {:halt,
         update(socket, error: Format.error(reason), node_input: node, cookie_input: cookie)}
    end
  end

  defp connect_kubectl(ctx) do
    container = if ctx.container in [nil, ""], do: nil, else: ctx.container

    with {:ok, image} <- Kubectl.pod_image(ctx.cluster, ctx.namespace, ctx.pod, container) do
      connect_as({:kubectl, Kubectl.image_repository(image)}, ctx.pod, ctx.server, fn ->
        Target.connect_via_kubectl(
          ctx.cluster,
          ctx.namespace,
          ctx.pod,
          ctx.container,
          ctx.binary,
          ctx.server
        )
      end)
    end
  catch
    :exit, reason -> {:error, {:connect_failed, reason}}
  end

  defp connect_saved(entry, server) do
    connect_as({:kubectl, entry["app"]}, entry["pod"], server, fn ->
      Target.connect_saved_kubectl(entry, server)
    end)
  catch
    :exit, reason -> {:error, {:connect_failed, reason}}
  end

  defp connect_as(identity, label, server, connect) do
    with :ok <- Connections.check_application(identity, label),
         {:ok, info} <- connect.() do
      Connections.record_application(server, identity)
      {:ok, Map.put(info, :identity, identity)}
    end
  end

  defp connect_saved_kube(socket, entry) do
    if socket.assigns.conn.connecting do
      socket
    else
      ctx = %{
        cluster: entry["kubeconfig"],
        namespace: entry["namespace"],
        pod: entry["pod"],
        container: entry["container"],
        binary: entry["binary"],
        server: Connections.target_for_connect()
      }

      Settings.put_kube_selection(%{
        "cluster" => ctx.cluster,
        "namespace" => ctx.namespace,
        "pod" => ctx.pod,
        "container" => ctx.container,
        "binary" => ctx.binary
      })

      pid = self()

      {:ok, _} =
        Task.start(fn ->
          send(pid, {:beamdash_kube_connected, ctx, connect_saved(entry, ctx.server)})
        end)

      socket
      |> update(
        kube_cluster: ctx.cluster,
        kube_namespace: ctx.namespace,
        kube_pod: ctx.pod,
        kube_container: ctx.container,
        kube_binary: ctx.binary,
        error: nil
      )
      |> put_progress(:connecting, progress_step("Connecting…", nil))
    end
  end

  defp save_kube_connection(ctx, %{node: node, identity: {_kind, app}}) do
    LastConnection.put(%{
      "kind" => "kubectl",
      "node" => Atom.to_string(node),
      "app" => app,
      "cookie" => cookie_text(Target.cookie(ctx.server)),
      "kubeconfig" => ctx.cluster,
      "namespace" => ctx.namespace,
      "pod" => ctx.pod,
      "container" => ctx.container,
      "binary" => ctx.binary
    })
  end

  defp cookie_text(nil), do: ""
  defp cookie_text(cookie) when is_atom(cookie), do: Atom.to_string(cookie)
  defp cookie_text(cookie) when is_binary(cookie), do: cookie

  defp saved_pod_unavailable(socket, ctx, reason) do
    socket
    |> update(
      error:
        "Could not reach the saved pod #{ctx.pod} (#{Format.error(reason)}). Pick a pod and connect.",
      connecting: nil,
      kube_namespace: ctx.namespace,
      kube_pods: nil,
      kube_pods_listing: true,
      kube_pod: "",
      kube_containers: nil,
      kube_container: nil,
      kube_binaries: nil,
      kube_binary: nil
    )
    |> start_kube_listing(ctx.cluster, ctx.namespace, :pods, %{
      "cluster" => ctx.cluster,
      "namespace" => ctx.namespace,
      "pod" => ""
    })
  end

  # One tick chain at a time: it runs while any progress is active and clears
  # `progress_timer` when it stops, so a step set later starts a new chain.
  defp own_server?(socket, server),
    do: GenServer.whereis(server) == GenServer.whereis(socket.assigns.conn.server)

  defp put_progress(socket, key, step) do
    socket |> update([{key, step}]) |> start_progress_timer(step)
  end

  defp put_other_progress(socket, server, step) do
    others = socket.assigns.conn.connecting_others

    others =
      if step, do: Map.put(others, server, step), else: Map.delete(others, server)

    socket |> update(connecting_others: others) |> start_progress_timer(step)
  end

  defp start_progress_timer(socket, nil), do: socket

  defp start_progress_timer(socket, _step) do
    if socket.assigns.conn.progress_timer do
      socket
    else
      Process.send_after(self(), :beamdash_progress_tick, @progress_ms)
      update(socket, progress_timer: true)
    end
  end

  defp progress_step(label, command),
    do: %{label: label, command: command, since: System.monotonic_time(:millisecond), elapsed: 0}

  defp active_progress?(socket) do
    map_size(socket.assigns.conn.connecting_others) > 0 or
      Enum.any?([:connecting, :kube_progress], fn key -> socket.assigns.conn[key] end)
  end

  defp tick_progress(socket, key) do
    case socket.assigns.conn[key] do
      nil -> socket
      step -> update(socket, [{key, %{step | elapsed: elapsed(step)}}])
    end
  end

  defp tick_other_progress(socket) do
    others =
      Map.new(socket.assigns.conn.connecting_others, fn {server, step} ->
        {server, %{step | elapsed: elapsed(step)}}
      end)

    update(socket, connecting_others: others)
  end

  defp elapsed(step), do: div(System.monotonic_time(:millisecond) - step.since, 1000)

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
  # The selection is stored by the controller, so every selection goes through
  # it and the page reloads. Without a path, the controller returns to the page
  # the request came from.
  defp to_system(socket, node), do: select_and_go(socket, node, "/system")

  defp to_node(socket, node), do: select_and_go(socket, node, nil)

  defp select_and_go(socket, node, path) do
    params = %{"node" => Atom.to_string(node)}
    params = if path, do: Map.put(params, "return_to", path), else: params
    redirect(socket, to: "/connections/select?" <> URI.encode_query(params))
  end

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
