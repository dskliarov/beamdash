defmodule Beamdash.SeqTracer do
  @moduledoc """
  Sequential tracing (seq_trace) through erlyberly.

  `start/4` makes every call of a function start a seq_trace token, so the
  messages it causes, and the messages *those* cause, are recorded across
  processes. erlyberly's seq_trace collector on the target holds them until
  we fetch them, so this process polls once a second while a seq trace is
  active.

  Subscribers receive `{:beamdash_seq, {:events, [event]}}`,
  `{:beamdash_seq, :traces_changed}` and `{:beamdash_seq, :cleared}`.
  """

  use GenServer

  alias Beamdash.{Record, Target}

  @poll_ms 1_000
  @max_events 2_000

  defstruct target: Target,
            tracer: Beamdash.Tracer,
            node: nil,
            traces: MapSet.new(),
            events: [],
            next_id: 1,
            subscribers: %{},
            polling: false,
            aliases: %{}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Seq trace calls of `mod:fun/arity`. Always uses a local trace pattern:
  a global one (what erlyberly picks for exported functions) misses calls
  made from inside the module, like `checkout(Item)` from a loop.
  """
  def start(mod, fun, arity, server \\ __MODULE__),
    do: GenServer.call(server, {:start, mod, fun, arity, false}, 10_000)

  def stop(mod, fun, arity, server \\ __MODULE__),
    do: GenServer.call(server, {:stop, mod, fun, arity}, 10_000)

  @doc "Stops every seq trace."
  def stop_all(server \\ __MODULE__), do: GenServer.call(server, :stop_all, 10_000)

  def traces(server \\ __MODULE__),
    do: GenServer.call(server, :traces) |> Enum.map(fn {m, f, a, _} -> {m, f, a} end)

  @doc "Events, oldest first."
  def events(server \\ __MODULE__), do: GenServer.call(server, :events)
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc "Fetch new events from the target now (normally done by the poll)."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 10_000)

  ## GenServer

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target, Target)
    :ok = Target.subscribe(target)
    %{node: node} = Target.status(target)

    {:ok,
     %__MODULE__{target: target, tracer: Keyword.get(opts, :tracer, Beamdash.Tracer), node: node}}
  end

  @impl true
  def handle_call({:start, _m, _f, _a, _e}, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:start, mod, fun, arity, exported?}, _from, state) do
    # erlyberly also makes sure its main trace collector runs, reporting to
    # the Tracer; it needs that collector's tracer process.
    ui_pid = GenServer.whereis(state.tracer) || self()
    args = [{node(), ui_pid}, mod, fun, arity, exported?]

    case Target.rpc(state.node, :erlyberly, :seq_trace, args) do
      {:ok, :ok} ->
        state = %{state | traces: MapSet.put(state.traces, {mod, fun, arity, exported?})}
        notify(state, :traces_changed)
        {:reply, :ok, schedule_poll(state)}

      {:ok, other} ->
        {:reply, {:error, {:trace_failed, other}}, state}

      {:error, reason} ->
        {:reply, {:error, {:trace_failed, reason}}, state}
    end
  end

  def handle_call({:stop, mod, fun, arity}, _from, state) do
    case Enum.find(state.traces, &match?({^mod, ^fun, ^arity, _}, &1)) do
      nil ->
        {:reply, :ok, state}

      {_, _, _, exported?} = t ->
        if state.node,
          do: Target.rpc(state.node, :erlyberly, :stop_seq_trace, [mod, fun, arity, exported?])

        state = fetch(%{state | traces: MapSet.delete(state.traces, t)})
        notify(state, :traces_changed)
        {:reply, :ok, state}
    end
  end

  def handle_call(:stop_all, _from, state) do
    if MapSet.size(state.traces) == 0 do
      {:reply, :ok, state}
    else
      if state.node do
        for {mod, fun, arity, exported?} <- state.traces,
            do: Target.rpc(state.node, :erlyberly, :stop_seq_trace, [mod, fun, arity, exported?])
      end

      state = fetch(%{state | traces: MapSet.new()})
      notify(state, :traces_changed)
      {:reply, :ok, state}
    end
  end

  def handle_call(:traces, _from, state),
    do: {:reply, state.traces |> MapSet.to_list() |> Enum.sort(), state}

  def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

  def handle_call(:clear, _from, state) do
    notify(state, :cleared)
    {:reply, :ok, %{state | events: []}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  def handle_call(:poll, _from, state), do: {:reply, :ok, fetch(state)}

  @impl true
  def handle_info(:poll, state) do
    state = fetch(%{state | polling: false})
    {:noreply, if(MapSet.size(state.traces) > 0, do: schedule_poll(state), else: state)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, state),
    do: {:noreply, %{state | node: node, traces: MapSet.new()}}

  def handle_info({:beamdash_target, {:disconnected, _}}, state) do
    state = %{state | node: nil, traces: MapSet.new()}
    notify(state, :traces_changed)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  ## Helpers

  defp schedule_poll(%{polling: true} = state), do: state

  defp schedule_poll(state) do
    Process.send_after(self(), :poll, @poll_ms)
    %{state | polling: true}
  end

  defp fetch(%{node: nil} = state), do: state

  defp fetch(state) do
    result = Target.rpc(state.node, :erlyberly, :collect_seq_trace_logs, [])
    drop_seq_token()

    case result do
      {:ok, {:ok, []}} ->
        state

      {:ok, {:ok, logs}} ->
        {new, next_id} =
          Enum.map_reduce(logs, state.next_id, &{to_event(&1, &2, state.node), &2 + 1})

        {new, state} = resolve_aliases(new, state)
        notify(state, {:events, new})
        events = Enum.take(Enum.reverse(new, state.events), @max_events)
        %{state | events: events, next_id: next_id}

      _ ->
        state
    end
  end

  # A seq_trace token travels with every message, across nodes too. Should
  # one reach this process (in a reply from the target), it would ride along
  # on everything sent from here and make beamdash's own messages show up
  # as traced events, so it is dropped.
  defp drop_seq_token, do: _ = :seq_trace.set_token([])

  defp to_event(props, id, node) do
    %{
      id: id,
      type: props[:msg_type],
      serial: props[:serial],
      from: props[:from] |> to_string() |> Target.localize_pid(node),
      to: props[:to] |> to_string() |> Target.localize_pid(node),
      message: Record.decode(props[:message]),
      timestamp_us: timestamp_us(props[:timestamp])
    }
  end

  # Since OTP 24 gen_server (and gen_statem) replies are sent to a process
  # alias, which erlyberly reports as "alias #Ref<...>". The alias comes
  # from the caller's {'$gen_call', {Pid, [alias | Ref]}, _} message, so
  # remember Ref -> caller and show replies as going back to the caller.
  defp resolve_aliases(events, state) do
    Enum.map_reduce(events, state, fn event, state ->
      state =
        case event.message do
          {:"$gen_call", {pid, [:alias | ref]}, _} when is_pid(pid) and is_reference(ref) ->
            put_in(
              state.aliases[ref_key(:erlang.ref_to_list(ref))],
              List.to_string(:erlang.pid_to_list(pid))
            )

          _ ->
            state
        end

      to =
        case event.to do
          "alias " <> ref -> Map.get(state.aliases, ref_key(String.to_charlist(ref)), event.to)
          to -> to
        end

      {%{event | to: to}, state}
    end)
  end

  # "#Ref<0.1.2.3>" on the target and "#Ref<25510.1.2.3>" here are the same
  # reference; compare without the node part.
  defp ref_key(chars), do: chars |> to_string() |> String.replace(~r/^#Ref<\d+\./, "")

  defp timestamp_us({mega, sec, micro}), do: (mega * 1_000_000 + sec) * 1_000_000 + micro
  defp timestamp_us(_), do: nil

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:beamdash_seq, event}) end)
  end
end
