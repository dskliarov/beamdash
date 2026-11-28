defmodule Beamdash.Connections do
  @moduledoc """
  The nodes beamdash is connected to, one `Beamdash.Target` each.

  The first connection is the well-known `Beamdash.Target`, started by the
  application, so the single-instance services keep reading that node by
  default. Further connections (only with `Beamdash.Settings.multiple_connections?/0`
  on) are `Beamdash.Target` processes under `Beamdash.Connections.Supervisor`,
  addressed by pid. A connection that is neither connected nor reconnecting is
  not listed, and `prune/0` ends the extra ones.

  Changes are broadcast on the `"connections"` PubSub topic as
  `{:beamdash_connections, :changed}`.
  """

  alias Beamdash.{
    AnomalyMonitor,
    Crashes,
    Kubectl,
    Logs,
    Profiler,
    Sampler,
    Settings,
    SeqTracer,
    Store,
    SysTracer,
    Target,
    Tracer
  }

  @primary Beamdash.Target
  @supervisor Beamdash.Connections.Supervisor
  @topic "connections"
  @apps {__MODULE__, :apps}

  def supervisor_spec,
    do: {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}

  def subscribe, do: Phoenix.PubSub.subscribe(Beamdash.PubSub, @topic)

  @doc "Every live connection: `%{server, node, status, reconnecting, identity}`, the first connection first."
  def list do
    [@primary | extra()]
    |> Enum.filter(&listed?/1)
    |> Enum.map(fn server ->
      status = Target.status(server)

      %{
        server: server,
        node: status.node,
        status: status.status,
        reconnecting: Target.reconnecting(server),
        identity: recorded(server, status.node)
      }
    end)
  end

  @doc "The connections that are connected now."
  def connected, do: Enum.filter(list(), &(&1.status == :connected))

  @doc "The application a direct node runs: the prefix of its name before `@`."
  def node_app(node), do: node |> String.split("@", parts: 2) |> hd()

  @doc """
  The application the connected connections run, `{:direct, name}` or
  `{:kubectl, repository}`, from the first connected one that has one. `nil`
  when nothing is connected.
  """
  def app, do: Enum.find_value(connected(), & &1.identity)

  defp recorded(server, node) do
    case Map.get(apps(), server) do
      {identity, recorded_node} when node in [nil, recorded_node] -> identity
      _ -> nil
    end
  end

  @doc "A string that identifies the connection `server` in a page's events, also while it has no node."
  def key(server), do: server |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  @doc "The connection whose `key/1` is `key`, or `nil`."
  def find_key(key), do: Enum.find(list(), &(key(&1.server) == key))

  @doc """
  `:ok` when a connection with `identity` (`{:direct, name}` or
  `{:kubectl, repository}`, shown as `label`) may be added. With multiple
  connections off a connect replaces the current one, so it always may.
  """
  def check_application(identity, label) do
    fixed = app()

    if Settings.multiple_connections?() and fixed not in [nil, identity] do
      {_, fixed_name} = fixed
      {_, other} = identity
      {:error, {:different_application, fixed_name, label, other}}
    else
      :ok
    end
  end

  @doc "Records the application `identity` runs on the connected `server`."
  def record_application(server, identity) do
    connections = list()
    live = Enum.map(connections, & &1.server)
    apps = Map.take(apps(), live)

    apps =
      case Enum.find(connections, &(&1.server == server)) do
        %{node: node} -> Map.put(apps, server, {identity, node})
        nil -> apps
      end

    :persistent_term.put(@apps, apps)
  end

  defp apps, do: :persistent_term.get(@apps, %{})

  @doc "The connected connection to `input` (`\"api@host\"`, or `\"api\"` for any host), or `nil`."
  def find_node(input) do
    Enum.find(connected(), fn %{node: node} ->
      name = Atom.to_string(node)
      name == input or (not String.contains?(input, "@") and hd(String.split(name, "@")) == input)
    end)
  end

  @doc """
  The target to connect next: the first connection when it is free, else a
  new one. Without multiple connections, every other connection is
  disconnected first, so a connect replaces the current one.
  """
  def target_for_connect do
    if Settings.multiple_connections?() do
      if free?(@primary), do: @primary, else: start_extra()
    else
      Enum.each(extra(), &remove/1)
      @primary
    end
  end

  @doc """
  `count` distinct targets for a batch connect with multiple connections on:
  the first connection when it is free, the rest new ones. Calling
  `target_for_connect/0` in a loop would hand the free first connection out
  twice, since it stays free until its connect replies.
  """
  def targets_for_connect(count) do
    [target_for_connect() | for(_ <- 2..count//1, do: start_extra())]
  end

  @doc """
  Adds a connection to `node`, a node the connected `source` is connected to,
  reached the way `source` reaches it. The other connections stay.
  """
  def connect_from(source, node) do
    server = target_for_connect()

    with {:ok, identity, connect} <- route(source, node, server),
         :ok <- check_application(identity, Atom.to_string(node)),
         {:ok, info} <- connect.() do
      record_application(server, identity)
      broadcast()
      {:ok, info}
    else
      error ->
        discard(server)
        error
    end
  end

  defp route(source, node, server) do
    case Target.route_to(node, source) do
      {:direct, cookie} ->
        {:ok, {:direct, node_app(Atom.to_string(node))},
         fn -> Target.connect(node, cookie, server) end}

      {:kubectl, kubeconfig, namespace, container, binary} ->
        with {:ok, {namespace, pod}} <- Kubectl.find_pod(kubeconfig, namespace, node),
             {:ok, image} <- Kubectl.pod_image(kubeconfig, namespace, pod, container) do
          {:ok, {:kubectl, Kubectl.image_repository(image)},
           fn ->
             Target.connect_via_kubectl(kubeconfig, namespace, pod, container, binary, server)
           end}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Ends a connection that was never made (a failed connect on a new target)."
  def discard(server) do
    if server in extra() and Target.status(server).status == :disconnected do
      remove(server)
      broadcast()
    end

    :ok
  end

  @doc "Ends the extra connections that dropped and are not reconnecting."
  def prune do
    for server <- extra(), not listed?(server), do: remove(server)
    :ok
  end

  @doc "Disconnects `server` and, for an extra connection, stops its supervisor and instances."
  def remove(server) do
    if live?(server), do: Target.disconnect(server)

    case connection_sup(server) do
      nil -> :ok
      sup -> DynamicSupervisor.terminate_child(@supervisor, sup)
    end

    broadcast()
    :ok
  end

  @doc """
  The pid of `module`'s instance for the connection `server`, or `nil`. The
  first connection's instances are the singletons, so for it this is `module`.
  """
  def service(@primary, module), do: module

  def service(server, module) do
    with sup when is_pid(sup) <- connection_sup(server), do: instance(sup, module)
  end

  @doc """
  Stops `module`'s run on the extra connection `server`. The connection stays
  up and the other instances keep running. Returns `{:error, :not_found}`
  when that instance is not running.
  """
  def stop_service(server, module) do
    case connection_sup(server) do
      nil -> {:error, :not_found}
      sup -> Supervisor.terminate_child(sup, module)
    end
  end

  @doc """
  Starts `module`'s run on the extra connection `server` again, after
  `stop_service/2`. Returns `{:error, :running}` when it is already running.
  """
  def start_service(server, module) do
    case connection_sup(server) do
      sup when is_pid(sup) ->
        cond do
          instance(sup, module) ->
            {:error, :running}

          startable?(module) ->
            Supervisor.start_child(
              sup,
              service_spec(module, instance_opts(sup, target_of(sup), module))
            )

          true ->
            {:error, :not_found}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Tells every page that the connections changed."
  def broadcast,
    do: Phoenix.PubSub.broadcast(Beamdash.PubSub, @topic, {:beamdash_connections, :changed})

  defp free?(server) do
    Target.status(server).status == :disconnected and Target.reconnecting(server) == nil
  end

  @extra_services [
    AnomalyMonitor,
    Logs,
    Sampler,
    Crashes,
    Tracer,
    SysTracer,
    SeqTracer,
    Profiler
  ]

  # The connection's supervisor ends with its Target: a significant temporary
  # child stops the supervisor, so no instance outlives its connection.
  defp start_extra do
    target_spec =
      Target.child_spec(name: nil)
      |> Map.merge(%{restart: :temporary, significant: true})

    opts = [strategy: :one_for_one, auto_shutdown: :any_significant]

    {:ok, sup} =
      DynamicSupervisor.start_child(@supervisor, %{
        id: Supervisor,
        start: {Supervisor, :start_link, [[target_spec], opts]},
        restart: :temporary,
        type: :supervisor
      })

    target = target_of(sup)

    for module <- @extra_services, startable?(module) do
      {:ok, _} =
        Supervisor.start_child(sup, service_spec(module, instance_opts(sup, target, module)))
    end

    target
  end

  defp startable?(Sampler), do: Store.path() != nil
  defp startable?(_module), do: true

  defp instance_opts(sup, target, Sampler),
    do: [target: target, monitor: instance(sup, AnomalyMonitor), logs: instance(sup, Logs)]

  defp instance_opts(sup, target, SeqTracer),
    do: [target: target, tracer: instance(sup, Tracer)]

  defp instance_opts(_sup, target, _module), do: [target: target]

  defp service_spec(module, opts),
    do: Supervisor.child_spec({module, Keyword.put(opts, :name, nil)}, restart: :temporary)

  defp instance(sup, module) do
    Enum.find_value(Supervisor.which_children(sup), fn
      {^module, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp extra do
    @supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, sup, _, _} when is_pid(sup) -> List.wrap(target_of(sup))
      _ -> []
    end)
  end

  defp connection_sup(server) do
    @supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_, sup, _, _} when is_pid(sup) -> if target_of(sup) == server, do: sup
      _ -> nil
    end)
  end

  defp target_of(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Target, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  # The first connection is never ended, since the singleton services read it.
  defp listed?(server) do
    live?(server) and
      (Target.status(server).status == :connected or Target.reconnecting(server) != nil)
  end

  defp live?(server) do
    pid = pid_of(server)
    pid != nil and Process.alive?(pid)
  end

  defp pid_of(server) when is_pid(server), do: server
  defp pid_of(name), do: Process.whereis(name)
end
