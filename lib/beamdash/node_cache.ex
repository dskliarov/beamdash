defmodule Beamdash.NodeCache do
  @moduledoc """
  A value read from the connected node, kept for the pages that need it. It
  is fetched at startup and when the target connects, then refreshed every 5
  minutes in the background, so readers do not each wait for the node.

  A fetch that times out is tried again with 10 % and then 20 % more time than
  the trace timeout. After the last attempt the readers get the error, and the
  next fetch starts after double the first attempt.
  """
  use GenServer

  alias Beamdash.{Settings, Target}

  @refresh_ms 300_000
  @attempt_percent [100, 110, 120]

  defstruct [:target, :fetch, :node, :value, :task, :retry_timer, attempt: 0, waiting: []]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "The value, `{:ok, value}`, or the error of the fetch; a timeout while waiting is the timeout error."
  def get(server) do
    GenServer.call(server, :get, call_timeout())
  catch
    :exit, {:timeout, _} -> {:error, {:error, {:erpc, :timeout}}}
  end

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target, Target)
    :ok = Target.subscribe(target)
    %{status: status, node: node} = Target.status(target)
    send(self(), :refresh)

    {:ok,
     %__MODULE__{
       target: target,
       fetch: Keyword.fetch!(opts, :fetch),
       node: if(status == :connected, do: node)
     }}
  end

  @impl true
  def handle_call(:get, _from, %{value: value} = state) when value != nil,
    do: {:reply, {:ok, value}, state}

  def handle_call(:get, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(:get, from, state),
    do: {:noreply, %{fetch(state) | waiting: [from | state.waiting]}}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    if timed_out?(result) and state.attempt < length(@attempt_percent) - 1 do
      {:noreply, fetch(%{state | attempt: state.attempt + 1})}
    else
      Enum.each(state.waiting, &GenServer.reply(&1, result))

      value = if state.node, do: value_from(result, state.value)
      state = %{state | waiting: [], value: value, attempt: 0}
      {:noreply, if(timed_out?(result), do: pause(state), else: state)}
    end
  end

  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, fetch(state)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, state),
    do: {:noreply, fetch(%{stop_fetch(state) | node: node, value: nil})}

  def handle_info({:beamdash_target, {:disconnected, _}}, state) do
    state = stop_fetch(state)
    Enum.each(state.waiting, &GenServer.reply(&1, {:error, :not_connected}))
    {:noreply, %{state | node: nil, value: nil, waiting: []}}
  end

  def handle_info(:retry, state), do: {:noreply, fetch(%{state | retry_timer: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  defp fetch(%{task: nil, node: node, retry_timer: nil} = state) when node != nil do
    fetch_fun = state.fetch
    timeout = attempt_timeout(state.attempt)
    %{state | task: Task.async(fn -> run(fetch_fun, node, timeout) end)}
  end

  defp fetch(state), do: state

  defp stop_fetch(state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    %{state | task: nil, retry_timer: nil, attempt: 0}
  end

  # after the last attempt times out, the next fetch waits double the first attempt
  defp pause(state),
    do: %{state | retry_timer: Process.send_after(self(), :retry, 2 * trace_timeout())}

  defp attempt_timeout(attempt),
    do: div(trace_timeout() * Enum.at(@attempt_percent, attempt), 100)

  # the attempts together, and a little for the answer to come back
  defp call_timeout, do: div(trace_timeout() * Enum.sum(@attempt_percent), 100) + 10_000

  defp trace_timeout, do: Settings.trace_timeout()

  defp run(fetch, node, timeout) do
    fetch.(node, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  # Target.rpc wraps the erpc reason in its own {:error, _}
  defp timed_out?({:error, {:error, {:erpc, :timeout}}}), do: true
  defp timed_out?({:error, {:timeout, _}}), do: true
  defp timed_out?(_), do: false

  defp value_from({:ok, value}, _old), do: value
  defp value_from(_error, old), do: old
end
