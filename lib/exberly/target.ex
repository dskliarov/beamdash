defmodule Exberly.Target do
  @moduledoc """
  The connection to the node being inspected (one node at a time).

  Connecting:

    1. starts distribution on this VM if it is not already running,
       choosing short or long names to match the target,
    2. sets the cookie for that one node (other connections are unaffected),
    3. connects as a *hidden* node, so we never show up in the target's
       `nodes()` or join its cluster,
    4. loads the helper modules (`:exberly_agent` for process info,
       `:erlyberly` for tracing) and reads basic node info.

  Subscribers receive `{:exberly_target, {:connected, node}}` and
  `{:exberly_target, {:disconnected, reason}}`.
  """

  use GenServer
  require Logger

  alias Exberly.AgentLoader

  @rpc_timeout 5_000
  @connect_timeout 15_000

  defstruct node: nil, subscribers: %{}

  ## API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Connects to `node` (a string like `\"foo@host\"` or just `\"foo\"`)."
  def connect(node, cookie \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:connect, node, cookie}, @connect_timeout)
  end

  def disconnect(server \\ __MODULE__), do: GenServer.call(server, :disconnect)

  @doc "Returns `%{status: :connected | :disconnected, node: node() | nil}`."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Subscribes the calling process to connection events (again: no-op)."
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  def processes(server \\ __MODULE__), do: call_agent(server, :processes, [])

  def node_info(server \\ __MODULE__), do: call_agent(server, :node_info, [])

  @doc "What Observer's System tab shows (see `exberly_agent:system_info/0`)."
  def system_info(server \\ __MODULE__), do: call_agent(server, :system_info, [])

  @doc """
  Memory, GC, reductions and mailbox details of one process (see
  `exberly_agent:process_details/2`), or `{:ok, :undefined}` if it has
  exited. Queued messages are only fetched when there are at most
  `max_messages` of them.
  """
  def process_details(pid, max_messages \\ 100, server \\ __MODULE__) when is_pid(pid),
    do: call_agent(server, :process_details, [pid, max_messages])

  @doc "Force a garbage collection; returns `%{before: bytes, after: bytes}`."
  def garbage_collect(pid, server \\ __MODULE__) when is_pid(pid),
    do: call_agent(server, :garbage_collect, [pid])

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
      %{status: :connected, node: node} -> rpc(node, :exberly_agent, fun, args)
      _ -> {:error, :not_connected}
    end
  end

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:connect, node_input, cookie}, _from, state) do
    state = drop_current(state, :reconnect)

    result =
      with {:ok, node} <- parse_node(node_input),
           :ok <- ensure_distributed(node),
           :ok <- put_cookie(node, cookie),
           :ok <- hidden_connect(node),
           :ok <- load_agent(node),
           {:ok, info} <- rpc(node, :exberly_agent, :node_info, []) do
        {:ok, node, info}
      end

    case result do
      {:ok, node, info} ->
        true = Node.monitor(node, true)
        remember_pid_index(node)
        notify(state, {:connected, node})
        {:reply, {:ok, info}, %{state | node: node}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    {:reply, :ok, drop_current(state, :user)}
  end

  def handle_call(:status, _from, %{node: nil} = state) do
    {:reply, %{status: :disconnected, node: nil}, state}
  end

  def handle_call(:status, _from, %{node: node} = state) do
    {:reply, %{status: :connected, node: node}, state}
  end

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
    Logger.info("exberly: lost connection to #{node}")
    notify(state, {:disconnected, :nodedown})
    {:noreply, %{state | node: nil}}
  end

  def handle_info({:nodedown, _other}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  ## Helpers

  defp drop_current(%{node: nil} = state, _reason), do: state

  defp drop_current(%{node: node} = state, reason) do
    # Remove erlyberly's crash-report handler (installed by
    # Exberly.Crashes) while we can still reach the node; left behind, it
    # would keep sending to our pid and make the target try to reconnect.
    rpc(node, :error_logger, :delete_report_handler, [:erlyberly])
    # Likewise switch off sys:trace on every process Exberly.SysTracer
    # traced (the collector there would do it anyway once we are gone).
    rpc(node, :exberly_agent, :sys_trace_stop_all, [])
    # and stop a profile that is running
    rpc(node, :exberly_agent, :tprof_stop, [])
    Node.monitor(node, false)
    Node.disconnect(node)
    notify(state, {:disconnected, reason})
    %{state | node: nil}
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:exberly_target, event}) end)
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

  # Long names when the target's host part is a dotted name or IP.
  defp ensure_distributed(target) do
    if Node.alive?() do
      :ok
    else
      [_, host] = target |> Atom.to_string() |> String.split("@", parts: 2)
      mode = if String.contains?(host, "."), do: :longnames, else: :shortnames
      name = :"exberly_#{System.unique_integer([:positive])}"

      case Node.start(name, mode) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> {:error, {:distribution_failed, reason}}
      end
    end
  end

  defp put_cookie(_node, cookie) when cookie in [nil, ""], do: :ok

  defp put_cookie(node, cookie) do
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

  @agent_modules [:exberly_agent, :erlyberly]

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
