defmodule Exberly.SysTracer do
  @moduledoc """
  `sys:trace/2` for OTP processes on the target (gen_server, gen_statem,
  gen_event, supervisor).

  `enable/1` calls `sys:trace(Pid, true)` on the target, so the process
  prints every event it handles on the target's console, as `sys:trace`
  always does, and also has a sys debug function copy each event to
  exberly (`exberly_agent:sys_trace/3`). `disable/1` calls
  `sys:trace(Pid, false)` and removes the function.

  The last 300 events of each traced process are kept here.
  Subscribers receive `{:exberly_sys_trace, pid, update}` where update is
  `{:events, [event]}`, `:enabled`, `:disabled`, `:cleared`,
  `{:dropped, n}` or `{:exited, reason}`. An event is
  `%{id, pid, at_us, event}`, `event` being the term sys reported (see
  `Exberly.SysEvent`); ids increase across all processes.

  If exberly disconnects or this process dies, the collector on the
  target turns tracing off everywhere it was on.
  """

  use GenServer

  alias Exberly.Target

  @max_events 300
  # the agent waits up to 5 s for a busy process to answer a sys request
  @rpc_timeout 10_000
  @call_timeout 15_000

  defstruct target: Target, node: nil, traced: %{}, next_id: 1, subscribers: %{}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Turns sys:trace on. `{:error, :timeout}` if the process did not answer."
  def enable(pid, server \\ __MODULE__) when is_pid(pid),
    do: GenServer.call(server, {:enable, pid}, @call_timeout)

  @doc "Turns sys:trace off."
  def disable(pid, server \\ __MODULE__) when is_pid(pid),
    do: GenServer.call(server, {:disable, pid}, @call_timeout)

  @doc "Pids being traced."
  def traced(server \\ __MODULE__), do: GenServer.call(server, :traced)

  @doc """
  `%{events: [event], dropped: n, exited: reason | nil}` for a traced
  process (events oldest first), or nil if it is not traced.
  """
  def info(pid, server \\ __MODULE__), do: GenServer.call(server, {:info, pid})

  def clear(pid, server \\ __MODULE__), do: GenServer.call(server, {:clear, pid})

  @doc """
  The kept events of every traced process merged, oldest first, plus the
  total of dropped events: `%{events: [event], dropped: n}`.
  """
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  ## GenServer

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target, Target)
    :ok = Target.subscribe(target)

    node =
      case Target.status(target) do
        %{status: :connected, node: node} -> node
        _ -> nil
      end

    {:ok, %__MODULE__{target: target, node: node}}
  end

  @impl true
  def handle_call({:enable, _pid}, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:enable, pid}, _from, state) do
    case Target.rpc(state.node, :exberly_agent, :sys_trace, [pid, true, self()], @rpc_timeout) do
      {:ok, :ok} ->
        entry = Map.get(state.traced, pid, new_entry())
        state = put_in(state.traced[pid], %{entry | exited: nil})
        notify(state, pid, :enabled)
        {:reply, :ok, state}

      {:ok, {:error, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disable, pid}, _from, state) do
    result =
      if state.node do
        case Target.rpc(
               state.node,
               :exberly_agent,
               :sys_trace,
               [pid, false, self()],
               @rpc_timeout
             ) do
          {:ok, :ok} -> :ok
          {:ok, {:error, :noproc}} -> :ok
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end

    # Forget it either way: on a timeout the agent switches tracing off as
    # soon as the process gets to the request.
    state = %{state | traced: Map.delete(state.traced, pid)}
    notify(state, pid, :disabled)
    {:reply, result, state}
  end

  def handle_call(:traced, _from, state), do: {:reply, Map.keys(state.traced), state}

  def handle_call(:all, _from, state) do
    events =
      state.traced
      |> Enum.flat_map(fn {_pid, e} -> :queue.to_list(e.events) end)
      |> Enum.sort_by(& &1.id)

    dropped = state.traced |> Map.values() |> Enum.map(& &1.dropped) |> Enum.sum()
    {:reply, %{events: events, dropped: dropped}, state}
  end

  def handle_call({:info, pid}, _from, state) do
    reply =
      case state.traced do
        %{^pid => e} -> %{events: :queue.to_list(e.events), dropped: e.dropped, exited: e.exited}
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:clear, pid}, _from, state) do
    case state.traced do
      %{^pid => e} ->
        state = put_in(state.traced[pid], %{e | events: :queue.new(), count: 0, dropped: 0})
        notify(state, pid, :cleared)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  @impl true
  # A batch from the collector on the target: [{pid, at_us, event}].
  def handle_info({:exberly_sys_events, batch, dropped}, state) do
    {state, by_pid} =
      Enum.reduce(batch, {state, %{}}, fn {pid, at, event}, {st, acc} ->
        case st.traced do
          %{^pid => _} ->
            ev = %{id: st.next_id, pid: pid, at_us: at, event: event}
            st = %{st | next_id: st.next_id + 1}
            st = update_in(st.traced[pid], &push(&1, ev))
            {st, Map.update(acc, pid, [ev], &[ev | &1])}

          _ ->
            {st, acc}
        end
      end)

    # Dropped events are counted against every traced process in the
    # batch: the collector does not know whose they were.
    state =
      if dropped > 0 do
        Enum.reduce(Map.keys(by_pid), state, fn pid, st ->
          update_in(st.traced[pid].dropped, &(&1 + dropped))
        end)
      else
        state
      end

    if dropped > 0, do: Enum.each(Map.keys(by_pid), &notify(state, &1, {:dropped, dropped}))

    Enum.each(by_pid, fn {pid, evs} ->
      evs = Enum.reverse(evs)
      notify(state, pid, {:events, evs})

      case List.last(evs) do
        %{event: {:exberly_exited, reason}} ->
          notify(state, pid, {:exited, reason})

        _ ->
          :ok
      end
    end)

    state =
      Enum.reduce(by_pid, state, fn {pid, evs}, st ->
        case Enum.find(evs, &match?(%{event: {:exberly_exited, _}}, &1)) do
          %{event: {:exberly_exited, reason}} -> put_in(st.traced[pid].exited, reason)
          nil -> st
        end
      end)

    {:noreply, state}
  end

  def handle_info({:exberly_target, {:connected, node}}, state),
    do: {:noreply, %{state | node: node, traced: %{}}}

  def handle_info({:exberly_target, {:disconnected, _}}, state) do
    Enum.each(Map.keys(state.traced), &notify(state, &1, :disabled))
    {:noreply, %{state | node: nil, traced: %{}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  ## Helpers

  defp new_entry, do: %{events: :queue.new(), count: 0, dropped: 0, exited: nil}

  defp push(%{events: q, count: n} = e, ev) when n >= @max_events,
    do: %{e | events: :queue.in(ev, :queue.drop(q))}

  defp push(%{events: q, count: n} = e, ev), do: %{e | events: :queue.in(ev, q), count: n + 1}

  defp notify(state, pid, update) do
    Enum.each(state.subscribers, fn {_ref, sub} ->
      send(sub, {:exberly_sys_trace, pid, update})
    end)
  end
end
