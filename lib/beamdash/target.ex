defmodule Beamdash.Target do
  @moduledoc """
  The connection to the node being inspected (one node at a time).

  Connecting:

    1. starts distribution on this VM if it is not already running,
       choosing short or long names to match the target,
    2. sets the cookie for that one node (other connections are unaffected),
    3. connects as a *hidden* node, so we never show up in the target's
       `nodes()` or join its cluster,
    4. loads the helper modules (`:beamdash_agent` for process info,
       `:erlyberly` for tracing) and reads basic node info.

  `connect_via_kubectl/5` reaches a node in a Kubernetes pod the same way,
  but first opens a `kubectl port-forward` tunnel to it (see
  `Beamdash.Kubectl`) and discovers its node name and cookie from the pod
  itself, since the pod's advertised address is not otherwise reachable
  through the forwarded port. The tunnel is closed whenever the connection
  it was opened for ends, same as a direct connection's distribution link.

  Subscribers receive `{:beamdash_target, {:connected, node}}` and
  `{:beamdash_target, {:disconnected, reason}}`.

  With auto-reconnect on (`Beamdash.Settings.auto_reconnect?/0`), a
  connection lost to the node going down (or its kubectl tunnel failing)
  is tried again the way it was made, in the background, after 1, 2, 5,
  10 and then every 15 s, until it succeeds, the user connects or
  disconnects, or the setting is turned off. `reconnecting/1` says how
  it goes; success is an ordinary `{:connected, node}`.

  `switch/2` moves the connection to another node of the attached node's
  cluster, with the cookie the attached node uses for it.
  """

  use GenServer
  require Logger

  alias Beamdash.{AgentLoader, Kubectl}

  @rpc_timeout 5_000
  @connect_timeout 15_000
  @kubectl_connect_timeout 60_000

  @reconnect_delays [1_000, 2_000, 5_000, 10_000, 15_000]

  defstruct node: nil,
            subscribers: %{},
            tunnel: nil,
            source: nil,
            params: nil,
            reconnect: nil,
            auto_reconnect: nil,
            reconnect_delays: @reconnect_delays

  ## API

  @doc """
  Options: `:name`, and for tests `:auto_reconnect` (a 0-arity function
  read when a connection is lost and before each try; default
  `Beamdash.Settings.auto_reconnect?/0`) and `:reconnect_delays` (ms
  between tries, the last one repeating).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Connects to `node` (a string like `\"foo@host\"` or just `\"foo\"`)."
  def connect(node, cookie \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:connect, node, cookie}, @connect_timeout)
  end

  @doc """
  Connects to a node running as `binary` (under `/app/bin`, see
  `Beamdash.Kubectl.list_binaries/5`) in `container` (see
  `Beamdash.Kubectl.list_containers/4`; `nil` or `""` for a single-container
  pod) in `pod`, in `namespace`, in the cluster `kubeconfig` points at (see
  `Beamdash.Kubectl.list_kubeconfigs/1`; `nil` or `""` uses `kubectl`'s own
  ambient config), by opening a `kubectl port-forward` tunnel to it and
  discovering its node name and cookie from the pod itself.
  """
  def connect_via_kubectl(kubeconfig, namespace, pod, container, binary, server \\ __MODULE__) do
    GenServer.call(
      server,
      {:connect_kubectl, kubeconfig, namespace, pod, container, binary},
      @kubectl_connect_timeout
    )
  end

  def disconnect(server \\ __MODULE__), do: GenServer.call(server, :disconnect)

  @doc """
  Connects to `node`, a node the attached node is connected to, with the
  cookie the attached node uses for it. Only for direct connections: a
  pod's peers aren't reachable through its kubectl tunnel.
  """
  def switch(node, server \\ __MODULE__) when is_atom(node),
    do: GenServer.call(server, {:switch, node}, @connect_timeout + @rpc_timeout)

  @doc """
  `nil`, or while a lost connection is being tried again
  `%{node: node, attempt: n, error: reason | nil, next_at: DateTime.t()}`
  (`error` from the previous try).
  """
  def reconnecting(server \\ __MODULE__), do: GenServer.call(server, :reconnecting)

  @doc "Stops trying to reconnect."
  def stop_reconnect(server \\ __MODULE__), do: GenServer.call(server, :stop_reconnect)

  @doc """
  The attached node and the nodes it is connected to:
  `{:ok, %{this: node, visible: [node], hidden: [node]}}`, sorted, without
  beamdash's own node among the hidden ones.
  """
  def cluster_nodes(server \\ __MODULE__) do
    case status(server) do
      %{status: :connected, node: node} ->
        with {:ok, visible} <- rpc(node, :erlang, :nodes, [:visible]),
             {:ok, hidden} <- rpc(node, :erlang, :nodes, [:hidden]) do
          {:ok, %{this: node, visible: Enum.sort(visible), hidden: Enum.sort(hidden -- [node()])}}
        end

      _ ->
        {:error, :not_connected}
    end
  end

  @doc "Returns `%{status: :connected | :disconnected, node: node() | nil}`."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Where the current connection came from: `nil` when disconnected, `:direct`
  for `connect/3`, or `{:kubectl, %{kubeconfig:, namespace:, pod:, container:}}`
  for `connect_via_kubectl/6` (`container` is `nil` for a single-container pod).
  """
  @spec source(GenServer.server()) ::
          nil
          | :direct
          | {:kubectl,
             %{
               kubeconfig: String.t() | nil,
               namespace: String.t(),
               pod: String.t(),
               container: String.t() | nil
             }}
  def source(server \\ __MODULE__), do: GenServer.call(server, :source)

  @doc "Subscribes the calling process to connection events (again: no-op)."
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  def processes(server \\ __MODULE__), do: call_agent(server, :processes, [])

  def node_info(server \\ __MODULE__), do: call_agent(server, :node_info, [])

  @doc "What Observer's System tab shows (see `beamdash_agent:system_info/0`)."
  def system_info(server \\ __MODULE__), do: call_agent(server, :system_info, [])

  @doc """
  Memory, GC, reductions and mailbox details of one process (see
  `beamdash_agent:process_details/2`), or `{:ok, :undefined}` if it has
  exited. Queued messages are only fetched when there are at most
  `max_messages` of them.
  """
  def process_details(pid, max_messages \\ 100, server \\ __MODULE__) when is_pid(pid),
    do: call_agent(server, :process_details, [pid, max_messages])

  @doc "Force a garbage collection; returns `%{before: bytes, after: bytes}`."
  def garbage_collect(pid, server \\ __MODULE__) when is_pid(pid),
    do: call_agent(server, :garbage_collect, [pid])

  @doc """
  The node's primary logger level and each running application's level:
  `%{primary: level, apps: [{app, level | :default | :mixed}]}`, sorted by
  application (see `beamdash_agent:log_levels/0`).
  """
  def log_levels(server \\ __MODULE__), do: call_agent(server, :log_levels, [])

  @doc """
  Sets the logger level of every module of `app` on the node, or removes
  those module levels with `:default`. `{:ok, :ok}`, or `{:ok, {:error,
  reason}}` from the node.
  """
  def set_app_log_level(app, level, server \\ __MODULE__) when is_atom(app) and is_atom(level),
    do: call_agent(server, :log_set_app_level, [app, level])

  @doc """
  Sets the node's primary logger level. `{:ok, :ok}`, or `{:ok, {:error,
  reason}}` from the node.
  """
  def set_primary_log_level(level, server \\ __MODULE__) when is_atom(level),
    do: call_agent(server, :log_set_primary_level, [level])

  @doc false
  def rpc(node, mod, fun, args, timeout \\ @rpc_timeout) do
    {:ok, :erpc.call(node, mod, fun, args, timeout)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # RPCs run in the caller's process, so a slow target never blocks
  # the GenServer (or other LiveViews).
  defp call_agent(server, fun, args) do
    case status(server) do
      %{status: :connected, node: node} -> rpc(node, :beamdash_agent, fun, args)
      _ -> {:error, :not_connected}
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       auto_reconnect: Keyword.get(opts, :auto_reconnect, &Beamdash.Settings.auto_reconnect?/0),
       reconnect_delays: Keyword.get(opts, :reconnect_delays, @reconnect_delays)
     }}
  end

  @impl true
  def handle_call({:connect, node_input, cookie}, _from, state) do
    state = state |> cancel_reconnect() |> drop_current(:reconnect)

    with {:ok, node} <- parse_node(node_input),
         {:ok, connection} <- establish({:direct, node, cookie}, self()) do
      {:reply, {:ok, connection.info}, connected(state, connection)}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:connect_kubectl, kubeconfig, namespace, pod, container, binary}, _from, state) do
    state = state |> cancel_reconnect() |> drop_current(:reconnect)
    params = {:kubectl, kubeconfig, namespace, pod, container, binary}

    case establish(params, self()) do
      {:ok, connection} -> {:reply, {:ok, connection.info}, connected(state, connection)}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:switch, _node}, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:switch, node}, _from, %{node: node} = state),
    do: {:reply, rpc(node, :beamdash_agent, :node_info, []), state}

  def handle_call({:switch, _node}, _from, %{params: {:kubectl, _, _, _, _, _}} = state),
    do: {:reply, {:error, :switch_needs_direct}, state}

  def handle_call({:switch, node}, from, %{params: {:direct, _, current_cookie}} = state) do
    # the cookie the attached node talks to `node` with (its own, unless
    # set per node), read before the connection to it is dropped
    cookie =
      case rpc(state.node, :erlang, :get_cookie, [node]) do
        {:ok, cookie} when is_atom(cookie) and cookie != :nocookie -> cookie
        _ -> current_cookie
      end

    handle_call({:connect, node, cookie}, from, state)
  end

  def handle_call(:disconnect, _from, state) do
    {:reply, :ok, state |> cancel_reconnect() |> drop_current(:user)}
  end

  def handle_call(:reconnecting, _from, %{reconnect: nil} = state), do: {:reply, nil, state}

  def handle_call(:reconnecting, _from, %{reconnect: r} = state),
    do: {:reply, Map.take(r, [:node, :attempt, :error, :next_at]), state}

  def handle_call(:stop_reconnect, _from, state), do: {:reply, :ok, cancel_reconnect(state)}

  def handle_call(:status, _from, %{node: nil} = state) do
    {:reply, %{status: :disconnected, node: nil}, state}
  end

  def handle_call(:status, _from, %{node: node} = state) do
    {:reply, %{status: :connected, node: node}, state}
  end

  def handle_call(:source, _from, state), do: {:reply, state.source, state}

  # once per process: the connection bar's hook and the page it is on run
  # in the same process and both subscribe
  def handle_call({:subscribe, pid}, _from, state) do
    if pid in Map.values(state.subscribers) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.subscribers[ref], pid)}
    end
  end

  @impl true
  def handle_info({:nodedown, node}, %{node: node} = state) do
    Logger.info("beamdash: lost connection to #{node}")
    Kubectl.close(state.tunnel)
    state = maybe_reconnect(state)
    notify(state, {:disconnected, :nodedown})
    {:noreply, %{state | node: nil, tunnel: nil, source: nil, params: nil}}
  end

  def handle_info({:nodedown, _other}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  # a kubectl port-forward died (cluster hiccup, pod restart): treat it the
  # same as the distribution link itself going down, instead of waiting for
  # net_kernel's own, much slower, tick timeout to notice.
  def handle_info({port, {:exit_status, _status}}, %{tunnel: tunnel} = state)
      when tunnel != nil and (port == tunnel.epmd_port or port == tunnel.dist_port) do
    Logger.warning("beamdash: lost the kubectl port-forward to #{inspect(state.node)}")
    {:noreply, state |> maybe_reconnect() |> drop_current(:tunnel_failed)}
  end

  def handle_info({:reconnect_try, ref}, %{reconnect: %{ref: ref} = r} = state) do
    if state.auto_reconnect.() do
      owner = self()

      {:ok, _} =
        Task.start(fn -> send(owner, {:reconnect_result, ref, establish(r.params, owner)}) end)

      {:noreply, state}
    else
      {:noreply, %{state | reconnect: nil}}
    end
  end

  def handle_info({:reconnect_try, _stale}, state), do: {:noreply, state}

  def handle_info({:reconnect_result, ref, {:ok, connection}}, %{reconnect: %{ref: ref}} = state) do
    Logger.info("beamdash: reconnected to #{connection.node}")
    {:noreply, connected(%{state | reconnect: nil}, connection)}
  end

  def handle_info(
        {:reconnect_result, ref, {:error, reason}},
        %{reconnect: %{ref: ref} = r} = state
      ) do
    {:noreply,
     %{state | reconnect: schedule_try(%{r | attempt: r.attempt + 1, error: reason}, state)}}
  end

  # a try that finished after the user connected, disconnected or stopped
  # it: undo what it set up, unless it reached the node now attached
  def handle_info({:reconnect_result, _stale, {:ok, connection}}, state) do
    Kubectl.close(connection.tunnel)
    if connection.node != state.node, do: Node.disconnect(connection.node)
    {:noreply, state}
  end

  def handle_info({:reconnect_result, _stale, {:error, _}}, state), do: {:noreply, state}

  # kubectl prints more than the one "Forwarding from" line `Kubectl`
  # already waited for (one per address family); nothing else we read a
  # port-forward's stdout for, so any further output from it is ignored.
  def handle_info({port, {:data, _data}}, state) when is_port(port) do
    {:noreply, state}
  end

  ## Helpers

  # Makes the connection `params` describes: `{:direct, node, cookie}` or
  # `{:kubectl, kubeconfig, namespace, pod, container, binary}`. Run in the
  # GenServer or, for a reconnect, in a task: kubectl's port-forwards are
  # then handed to `owner`, which watches them.
  defp establish({:direct, node, cookie} = params, _owner) do
    with {:ok, info} <- attach(node, cookie),
         do: {:ok, %{node: node, info: info, tunnel: nil, source: :direct, params: params}}
  end

  defp establish({:kubectl, kubeconfig, namespace, pod, container, binary} = params, owner) do
    with {:ok, %{node: node, cookie: cookie, tunnel: tunnel}} <-
           Kubectl.connect(kubeconfig, namespace, pod, container, binary) do
      if owner != self() do
        for port <- [tunnel.epmd_port, tunnel.dist_port] do
          Port.connect(port, owner)
          Process.unlink(port)
        end
      end

      case attach(node, cookie) do
        {:ok, info} ->
          source =
            {:kubectl,
             %{
               kubeconfig: kubeconfig,
               namespace: namespace,
               pod: pod,
               container: if(container in [nil, ""], do: nil, else: container)
             }}

          {:ok, %{node: node, info: info, tunnel: tunnel, source: source, params: params}}

        {:error, _} = error ->
          Kubectl.close(tunnel)
          error
      end
    end
  end

  defp attach(node, cookie) do
    with :ok <- ensure_distributed(node),
         :ok <- put_cookie(node, cookie),
         :ok <- hidden_connect(node),
         :ok <- load_agent(node),
         do: rpc(node, :beamdash_agent, :node_info, [])
  end

  defp connected(state, connection) do
    true = Node.monitor(connection.node, true)
    remember_pid_index(connection.node)
    notify(state, {:connected, connection.node})

    %{
      state
      | node: connection.node,
        tunnel: connection.tunnel,
        source: connection.source,
        params: connection.params
    }
  end

  # Starts trying the lost connection again, when the setting is on.
  defp maybe_reconnect(%{params: nil} = state), do: state

  defp maybe_reconnect(state) do
    if state.auto_reconnect.() do
      r = %{ref: make_ref(), params: state.params, node: state.node, attempt: 1, error: nil}
      %{state | reconnect: schedule_try(r, state)}
    else
      state
    end
  end

  defp schedule_try(r, state) do
    delays = state.reconnect_delays
    delay = Enum.at(delays, r.attempt - 1, List.last(delays))
    Process.send_after(self(), {:reconnect_try, r.ref}, delay)
    Map.put(r, :next_at, DateTime.add(DateTime.utc_now(), delay, :millisecond))
  end

  # a try still running reports with the old ref and is undone
  defp cancel_reconnect(state), do: %{state | reconnect: nil}

  defp drop_current(%{node: nil} = state, _reason), do: state

  defp drop_current(%{node: node} = state, reason) do
    # Remove erlyberly's crash-report handler (installed by
    # Beamdash.Crashes) while we can still reach the node; left behind, it
    # would keep sending to our pid and make the target try to reconnect.
    rpc(node, :error_logger, :delete_report_handler, [:erlyberly])
    # Likewise switch off sys:trace on every process Beamdash.SysTracer
    # traced (the collector there would do it anyway once we are gone).
    rpc(node, :beamdash_agent, :sys_trace_stop_all, [])
    # and remove the log handler Beamdash.Logs streams from
    rpc(node, :beamdash_agent, :log_detach, [])
    # and stop a profile that is running
    rpc(node, :beamdash_agent, :tprof_stop, [])
    Node.monitor(node, false)
    Node.disconnect(node)
    Kubectl.close(state.tunnel)
    notify(state, {:disconnected, reason})
    %{state | node: nil, tunnel: nil, source: nil, params: nil}
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:beamdash_target, event}) end)
  end

  @doc """
  Rewrites a pid string as printed *on the target* (`"<0.86.0>"`, what
  erlyberly sends) into the form pids from that node take here
  (`"<25516.86.0>"`), so the same process reads the same everywhere in
  the UI.
  """
  def localize_pid(pid_string, node) when is_binary(pid_string) do
    case :persistent_term.get({__MODULE__, :pid_index, node}, nil) do
      nil -> pid_string
      index -> String.replace(pid_string, ~r/^<0\./, "<#{index}.")
    end
  end

  def localize_pid(other, _node), do: other

  # The node index this VM gives the target's pids: read it off the
  # target's init process.
  defp remember_pid_index(node) do
    with {:ok, pid} when is_pid(pid) <- rpc(node, :erlang, :whereis, [:init]),
         [_, index] <- Regex.run(~r/^<(\d+)\./, List.to_string(:erlang.pid_to_list(pid))) do
      :persistent_term.put({__MODULE__, :pid_index, node}, index)
    end
  end

  @doc false
  def parse_node(input) when is_binary(input) do
    case String.trim(input) do
      "" ->
        {:error, :empty_node_name}

      name ->
        if String.contains?(name, "@") do
          {:ok, String.to_atom(name)}
        else
          {:ok, host} = :inet.gethostname()
          {:ok, String.to_atom("#{name}@#{host}")}
        end
    end
  end

  def parse_node(node) when is_atom(node), do: {:ok, node}

  # Long names when the target's host part is a dotted name or IP, short
  # names otherwise (a kubectl-discovered node's host is the pod name,
  # never dotted). Distribution stays up across connects to avoid
  # restarting it on every one, but a *mode* mismatch (e.g. switching from
  # a dotted direct target to a short-named pod, or back) makes Erlang
  # itself refuse the connection ("System running to use fully qualified
  # hostnames"), so that case restarts distribution with the right mode —
  # transparently, no user involvement needed.
  defp ensure_distributed(target) do
    [_, host] = target |> Atom.to_string() |> String.split("@", parts: 2)
    mode = if String.contains?(host, "."), do: :longnames, else: :shortnames

    cond do
      not Node.alive?() -> start_distributed(mode)
      current_name_domain() == mode -> :ok
      true -> restart_distributed(mode)
    end
  end

  defp current_name_domain do
    case :net_kernel.get_state() do
      %{name_domain: name_domain} -> name_domain
      _ -> nil
    end
  end

  # `:net_kernel.stop/0` only works on distribution started dynamically
  # (`Node.start/2`, what `start_distributed/1` below does); started
  # statically (`-sname`/`-name`, e.g. `iex --sname beamdash -S mix
  # phx.server`) it refuses with `{:error, :not_allowed}` — nothing to do
  # but report it, since restarting the whole VM is out of our hands.
  defp restart_distributed(mode) do
    case :net_kernel.stop() do
      :ok -> start_distributed(mode)
      {:error, reason} -> {:error, {:distribution_mode_locked, reason}}
    end
  end

  defp start_distributed(mode) do
    # Long names: use 127.0.0.1 as our own host rather than this
    # machine's hostname, which `:longnames` otherwise appends and
    # requires to resolve (it rarely does, e.g. over a kubectl tunnel to
    # a pod whose address is unrelated to this machine's actual name).
    # Same workaround as hot_load_via_portforward.exs's `run/4`.
    name =
      case mode do
        :longnames -> :"beamdash_#{System.unique_integer([:positive])}@127.0.0.1"
        :shortnames -> :"beamdash_#{System.unique_integer([:positive])}"
      end

    case Node.start(name, mode) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, {:distribution_failed, reason}}
    end
  end

  defp put_cookie(_node, cookie) when cookie in [nil, ""], do: :ok

  defp put_cookie(node, cookie) when is_atom(cookie) do
    true = Node.set_cookie(node, cookie)
    :ok
  end

  defp put_cookie(node, cookie) when is_binary(cookie) do
    true = Node.set_cookie(node, cookie |> String.trim() |> String.to_atom())
    :ok
  end

  defp hidden_connect(node) do
    case :net_kernel.hidden_connect_node(node) do
      true -> :ok
      false -> {:error, :connect_failed}
      :ignored -> {:error, :not_distributed}
    end
  end

  @agent_modules [:beamdash_agent, :erlyberly]

  defp load_agent(node) do
    result =
      Enum.reduce_while(@agent_modules, :ok, fn mod, :ok ->
        case AgentLoader.ensure_loaded(node, &rpc/4, mod) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:error, _} <- result, do: Node.disconnect(node)
    result
  end
end
