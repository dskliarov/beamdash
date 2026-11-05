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
  # a timed-out fetch is tried again with 10 % more, then 20 % more, node time
  @attempts [30_000, 33_000, 36_000]
  # after the last attempt times out, the next fetch waits double the first attempt
  @give_up_ms 60_000
  # the three attempts together take up to 99 s
  @call_timeout 120_000

  defstruct [:target, :tracer, :node, :modules, :task, :retry_timer, attempt: 0, waiting: []]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The loaded modules, `{:ok, [{mod, exports, locals}]}`, or the error of the fetch."
  def modules(server \\ __MODULE__), do: GenServer.call(server, :modules, @call_timeout)

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
    state = %{state | task: nil}

    if timed_out?(result) and state.attempt < length(@attempts) - 1 do
      {:noreply, fetch(%{state | attempt: state.attempt + 1})}
    else
      Enum.each(state.waiting, &GenServer.reply(&1, result))

      modules = if state.node, do: modules_from(result, state.modules)
      state = %{state | waiting: [], modules: modules, attempt: 0}
      {:noreply, if(timed_out?(result), do: pause(state), else: state)}
    end
  end

  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, fetch(state)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, state),
    do: {:noreply, fetch(%{stop_fetch(state) | node: node, modules: nil})}

  def handle_info({:beamdash_target, {:disconnected, _}}, state) do
    state = stop_fetch(state)
    Enum.each(state.waiting, &GenServer.reply(&1, {:error, :not_connected}))
    {:noreply, %{state | node: nil, modules: nil, waiting: []}}
  end

  def handle_info(:retry, state), do: {:noreply, fetch(%{state | retry_timer: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  defp fetch(%{task: nil, node: node, retry_timer: nil} = state) when node != nil do
    tracer = state.tracer
    timeout = Enum.at(@attempts, state.attempt)
    %{state | task: Task.async(fn -> fetch_modules(tracer, timeout) end)}
  end

  defp fetch(state), do: state

  defp stop_fetch(state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    %{state | task: nil, retry_timer: nil, attempt: 0}
  end

  defp pause(state),
    do: %{state | retry_timer: Process.send_after(self(), :retry, @give_up_ms)}

  defp fetch_modules(tracer, timeout) do
    Tracer.module_functions(tracer, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  # Target.rpc wraps the erpc reason in its own {:error, _}
  defp timed_out?({:error, {:error, {:erpc, :timeout}}}), do: true
  defp timed_out?({:error, {:timeout, _}}), do: true
  defp timed_out?(_), do: false

  defp modules_from({:ok, modules}, _old), do: modules
  defp modules_from(_error, old), do: old
end
