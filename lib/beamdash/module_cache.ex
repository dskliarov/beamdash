defmodule Beamdash.ModuleCache do
  @moduledoc """
  The modules loaded on the target, as `Beamdash.Tracer.module_functions/0`
  lists them. It is fetched at startup and when the target connects, then
  refreshed every 5 minutes in the background, so pages and Ask read it
  without each waiting for the node's module list.
  """
  use GenServer

  alias Beamdash.{Target, Tracer}

  @refresh_ms 300_000

  defstruct [:target, :tracer, :node, :modules, :task, waiting: []]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The loaded modules, `{:ok, [{mod, exports, locals}]}`, or the error of the fetch."
  def modules(server \\ __MODULE__), do: GenServer.call(server, :modules, 60_000)

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target, Target)
    :ok = Target.subscribe(target)
    %{status: status, node: node} = Target.status(target)
    send(self(), :refresh)

    {:ok,
     %__MODULE__{
       target: target,
       tracer: Keyword.get(opts, :tracer, Tracer),
       node: if(status == :connected, do: node)
     }}
  end

  @impl true
  def handle_call(:modules, _from, %{modules: modules} = state) when modules != nil,
    do: {:reply, {:ok, modules}, state}

  def handle_call(:modules, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(:modules, from, state),
    do: {:noreply, %{fetch(state) | waiting: [from | state.waiting]}}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Enum.each(state.waiting, &GenServer.reply(&1, result))

    modules = if state.node, do: modules_from(result, state.modules)
    {:noreply, %{state | task: nil, waiting: [], modules: modules}}
  end

  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, fetch(state)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, state),
    do: {:noreply, fetch(%{state | node: node, modules: nil})}

  def handle_info({:beamdash_target, {:disconnected, _}}, state),
    do: {:noreply, %{state | node: nil, modules: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  defp fetch(%{task: nil, node: node} = state) when node != nil do
    tracer = state.tracer
    %{state | task: Task.async(fn -> fetch_modules(tracer) end)}
  end

  defp fetch(state), do: state

  defp fetch_modules(tracer) do
    Tracer.module_functions(tracer)
  catch
    :exit, reason -> {:error, reason}
  end

  defp modules_from({:ok, modules}, _old), do: modules
  defp modules_from(_error, old), do: old
end
