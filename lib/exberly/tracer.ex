defmodule Exberly.Tracer do
  @moduledoc """
  Call tracing on the connected node, driven by erlyberly's trace collector
  (`lib/erlyberly.ex`, loaded into the target on connect).

  `start_trace/4` asks the target to trace `{mod, fun, arity}` and gives it
  this process's pid. erlyberly's collector then *sends* to us, so nothing
  is polled:

    * `{:erlyberly_trace_log, {:call | :return_from | :exception_from, props}}`
    * `{:erlyberly_trace_overload, queue_len}` – the collector fell behind, so
      erlyberly stopped all tracing (`dbg:stop_clear/0`)
    * `{:erlyberly_module_loaded, mod, functions}` – a traced module was
      reloaded and erlyberly re-applied its traces

  Calls and their returns arrive as separate messages. They are paired per
  process: each call is pushed on that pid's stack and the next return or
  exception from the same pid completes it.

  A trace can be limited to a number of calls (`start_trace/5` with
  `limit: n`): each call of the function counts down, and when the count
  reaches 0 its trace is switched off. Calls that still arrive while it is
  being switched off are not recorded, so the log holds exactly n calls.

  `start_trace(mod, :_, :_)` traces every function of `mod`, local ones
  included (`dbg:tpl({Mod, '_', '_'}, ...)`). It cannot be combined with
  traces of single functions of the same module (stopping one would clear
  the other), and is refused for the modules the tracing itself runs in
  (see `wildcard_allowed?/1`). Its call limit counts calls of any function
  of the module.

  Subscribers receive `{:exberly_trace, event}` where event is
  `{:entry, entry}` (new or completed), `:traces_changed`, `{:overload, n}`,
  `{:module_loaded, mod}`, `:cleared`, `{:remaining, mfa, n}` (calls left
  before a limited trace stops) or `{:limit_reached, mfa, limit}`.
  """

  use GenServer

  alias Exberly.{Record, Target}

  # Collector queue length at which erlyberly suspends tracing.
  @max_queue_len 1_000
  # Entries kept here for the UI.
  @max_entries 2_000

  defstruct target: Target,
            node: nil,
            traces: MapSet.new(),
            entries: %{},
            order: :queue.new(),
            open: %{},
            # {mod, fun, arity} => calls left, for traces with a call limit
            limits: %{},
            # {mod, fun, arity} => the limit it started with
            limit_totals: %{},
            next_id: 1,
            subscribers: %{}

  ## API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start_trace(mod, fun, arity, server \\ __MODULE__)

  def start_trace(mod, fun, arity, opts) when is_list(opts),
    do: start_trace(mod, fun, arity, opts, __MODULE__)

  def start_trace(mod, fun, arity, server), do: start_trace(mod, fun, arity, [], server)

  @doc """
  Traces `mod:fun/arity`. With `limit: n` (a positive integer) the trace
  switches itself off after n calls.
  """
  def start_trace(mod, fun, arity, opts, server) do
    limit = Keyword.get(opts, :limit)
    true = limit == nil or (is_integer(limit) and limit > 0)
    GenServer.call(server, {:start_trace, mod, fun, arity, limit}, 10_000)
  end

  # The trace collector, dbg and the runtime's own preloaded modules: tracing
  # every function of these would trace the tracing (or the whole VM).
  @no_wildcard ~w(erlyberly exberly_agent dbg erlang erts_internal erts_code_purger
                  erts_literal_area_collector erts_dirty_process_signal_handler erl_tracer
                  erl_prim_loader init prim_eval prim_file prim_inet prim_net prim_socket
                  prim_buffer prim_zip zlib atomics counters persistent_term socket_registry)a

  @doc "Whether every function of `mod` may be traced at once."
  def wildcard_allowed?(mod), do: is_atom(mod) and mod not in @no_wildcard

  @doc "Calls left for traces with a limit: `%{{mod, fun, arity} => n}`."
  def limits(server \\ __MODULE__), do: GenServer.call(server, :limits)

  def stop_trace(mod, fun, arity, server \\ __MODULE__),
    do: GenServer.call(server, {:stop_trace, mod, fun, arity}, 10_000)

  def stop_all(server \\ __MODULE__), do: GenServer.call(server, :stop_all, 10_000)

  @doc "Active traces as a sorted list of `{mod, fun, arity}`."
  def traces(server \\ __MODULE__), do: GenServer.call(server, :traces)

  @doc "Trace entries, newest first."
  def entries(server \\ __MODULE__), do: GenServer.call(server, :entries)

  def entry(id, server \\ __MODULE__), do: GenServer.call(server, {:entry, id})

  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc "Loaded modules on the target: `[{mod, exports, locals}]`."
  def module_functions(server \\ __MODULE__),
    do: GenServer.call(server, :module_functions, 30_000)

  ## GenServer

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target, Target)
    :ok = Target.subscribe(target)
    %{node: node} = Target.status(target)
    {:ok, %__MODULE__{target: target, node: node}}
  end

  @impl true
  def handle_call({:start_trace, mod, fun, arity, _limit}, _from, %{node: nil} = state)
      when is_atom(mod) and is_atom(fun) and (is_integer(arity) or arity == :_),
      do: {:reply, {:error, :not_connected}, state}

  def handle_call({:start_trace, mod, :_, :_, _limit}, _from, state)
      when mod in @no_wildcard,
      do: {:reply, {:error, {:wildcard_not_allowed, mod}}, state}

  def handle_call({:start_trace, mod, fun, arity, limit}, from, state) do
    cond do
      fun == :_ and Enum.any?(state.traces, &match?({^mod, _, _}, &1)) ->
        {:reply, {:error, {:functions_traced, mod}}, state}

      fun != :_ and MapSet.member?(state.traces, {mod, :_, :_}) ->
        {:reply, {:error, {:module_traced, mod}}, state}

      true ->
        do_start_trace({mod, fun, arity, limit}, from, state)
    end
  end

  def handle_call({:stop_trace, _mod, _fun, _arity}, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:stop_trace, mod, fun, arity}, _from, state) do
    {reply, state} = stop(state, {mod, fun, arity})
    state = %{state | limits: Map.delete(state.limits, {mod, fun, arity})}
    notify(state, :traces_changed)
    {:reply, reply, state}
  end

  def handle_call(:stop_all, _from, state) do
    if state.node, do: Target.rpc(state.node, :erlyberly, :stop_traces, [])
    state = %{state | traces: MapSet.new(), open: %{}, limits: %{}}
    notify(state, :traces_changed)
    {:reply, :ok, state}
  end

  def handle_call(:limits, _from, state),
    do: {:reply, Map.filter(state.limits, fn {_mfa, n} -> n > 0 end), state}

  def handle_call(:traces, _from, state),
    do: {:reply, state.traces |> MapSet.to_list() |> Enum.sort(), state}

  def handle_call(:entries, _from, state) do
    entries =
      state.order
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.flat_map(fn id -> List.wrap(state.entries[id]) end)

    {:reply, entries, state}
  end

  def handle_call({:entry, id}, _from, state), do: {:reply, state.entries[id], state}

  def handle_call(:clear, _from, state) do
    state = %{state | entries: %{}, order: :queue.new(), open: %{}}
    notify(state, :cleared)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  def handle_call(:module_functions, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(:module_functions, _from, state) do
    reply =
      case Target.rpc(state.node, :erlyberly, :module_functions, []) do
        {:ok, mods} -> {:ok, for({mod, exports, locals} <- mods, do: {mod, exports, locals})}
        error -> error
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:erlyberly_trace_log, log}, state) do
    {:noreply, handle_log(log, state)}
  end

  def handle_info({:erlyberly_trace_overload, queue_len}, state) do
    # erlyberly has already run dbg:stop_clear(): every trace is gone.
    state = %{state | traces: MapSet.new(), open: %{}, limits: %{}}
    notify(state, {:overload, queue_len})
    notify(state, :traces_changed)
    {:noreply, state}
  end

  # erlyberly reports every module load on the target; only reloads of
  # modules we are tracing matter (their traces were just re-applied).
  def handle_info({:erlyberly_module_loaded, mod, _functions}, state) do
    if Enum.any?(state.traces, &match?({^mod, _, _}, &1)),
      do: notify(state, {:module_loaded, mod})

    {:noreply, state}
  end

  def handle_info({:exberly_target, {:connected, node}}, state) do
    {:noreply, %{state | node: node, traces: MapSet.new(), open: %{}, limits: %{}}}
  end

  def handle_info({:exberly_target, {:disconnected, _}}, state) do
    state = %{state | node: nil, traces: MapSet.new(), open: %{}, limits: %{}}
    notify(state, :traces_changed)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  defp do_start_trace({mod, fun, arity, limit}, _from, state) do
    args = [{node(), self()}, mod, fun, arity, @max_queue_len]
    mfa = {mod, fun, arity}

    case Target.rpc(state.node, :erlyberly, :start_trace, args) do
      {:ok, {:ok, _collector}} ->
        # A finished trace of this module leaves its count at 0 to drop the
        # calls still arriving while it is switched off. A whole-module one
        # would otherwise swallow every call of the traces started now.
        stale? = fn {{m, _, _} = key, _} -> m == mod and key not in state.traces end
        limits = Map.reject(state.limits, stale?)
        totals = Map.reject(state.limit_totals, stale?)

        {limits, totals} =
          if limit,
            do: {Map.put(limits, mfa, limit), Map.put(totals, mfa, limit)},
            else: {Map.delete(limits, mfa), Map.delete(totals, mfa)}

        state = %{
          state
          | traces: MapSet.put(state.traces, mfa),
            limits: limits,
            limit_totals: totals
        }

        notify(state, :traces_changed)
        {:reply, :ok, state}

      {:ok, {:error, reason}} ->
        {:reply, {:error, {:trace_failed, reason}}, state}

      {:error, reason} ->
        {:reply, {:error, {:trace_failed, reason}}, state}
    end
  end

  ## Trace logs → entries

  defp handle_log({:call, props}, state) do
    {mod, fun, args} = Keyword.fetch!(props, :fn)
    pid = props |> Keyword.fetch!(:pid) |> to_string() |> Target.localize_pid(state.node)

    # a whole-module trace counts calls of any of its functions
    key =
      if Map.has_key?(state.limits, {mod, :_, :_}),
        do: {mod, :_, :_},
        else: {mod, fun, length(args)}

    case Map.fetch(state.limits, key) do
      # over the limit (arrived while the trace was being switched off):
      # not recorded; :dropped keeps its return from completing another call
      {:ok, 0} ->
        update_in(state.open[pid], &[:dropped | &1 || []])

      {:ok, left} ->
        props |> record_call(pid, state) |> count_down(key, left)

      :error ->
        record_call(props, pid, state)
    end
  end

  defp handle_log({kind, props}, state) when kind in [:return_from, :exception_from] do
    pid = props |> Keyword.fetch!(:pid) |> to_string() |> Target.localize_pid(state.node)

    result =
      case kind do
        :return_from -> {:return, Record.decode(props[:result])}
        :exception_from -> {:exception, Record.decode(props[:exception_from])}
      end

    {id, state} = pop_open(state, pid)
    traced_fn = props[:fn]

    case id && id != :dropped && state.entries[id] do
      false when id == :dropped ->
        # the return of a call over the limit, not recorded either
        state

      nil when traced_fn == nil ->
        # A return we cannot attribute to any function: drop it.
        state

      nil ->
        # The call was made before tracing started (or fell out of the
        # buffer): record the return on its own.
        {mod, fun, arity} = mfa_from(traced_fn)

        entry = %{
          id: state.next_id,
          pid: pid,
          reg_name: reg_name(props[:reg_name]),
          mod: mod,
          fun: fun,
          arity: arity,
          args: nil,
          call_us: nil,
          return_us: props[:timetamp_return_us],
          result: result,
          stack: []
        }

        put_entry(%{state | next_id: state.next_id + 1}, entry)

      entry ->
        put_entry(state, %{entry | result: result, return_us: props[:timetamp_return_us]})
    end
  end

  defp handle_log(_other, state), do: state

  defp record_call(props, pid, state) do
    {mod, fun, args} = Keyword.fetch!(props, :fn)

    entry = %{
      id: state.next_id,
      pid: pid,
      reg_name: reg_name(props[:reg_name]),
      mod: mod,
      fun: fun,
      arity: length(args),
      args: Enum.map(args, &Record.decode/1),
      call_us: props[:timetamp_call_us],
      return_us: nil,
      result: :pending,
      stack: props[:stack_trace] || []
    }

    state = %{state | next_id: state.next_id + 1}
    state = update_in(state.open[pid], &[entry.id | &1 || []])
    put_entry(state, entry)
  end

  # One call of a limited trace: one fewer left; at 0 the trace is switched
  # off on the target.
  defp count_down(state, mfa, left) do
    state = put_in(state.limits[mfa], left - 1)

    if left - 1 == 0 do
      {_reply, state} = stop(state, mfa)
      notify(state, {:limit_reached, mfa, Map.get(state.limit_totals, mfa)})
      notify(state, :traces_changed)
      state
    else
      notify(state, {:remaining, mfa, left - 1})
      state
    end
  end

  defp stop(%{node: nil} = state, mfa),
    do: {{:error, :not_connected}, %{state | traces: MapSet.delete(state.traces, mfa)}}

  defp stop(state, {mod, fun, arity} = mfa) do
    reply =
      case Target.rpc(state.node, :erlyberly, :stop_trace, [mod, fun, arity, true]) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {reply, %{state | traces: MapSet.delete(state.traces, mfa)}}
  end

  defp pop_open(state, pid) do
    case state.open[pid] do
      [id | rest] -> {id, %{state | open: Map.put(state.open, pid, rest)}}
      _ -> {nil, state}
    end
  end

  defp put_entry(state, entry) do
    state =
      if Map.has_key?(state.entries, entry.id) do
        put_in(state.entries[entry.id], entry)
      else
        %{
          state
          | entries: Map.put(state.entries, entry.id, entry),
            order: :queue.in(entry.id, state.order)
        }
        |> trim()
      end

    notify(state, {:entry, entry})
    state
  end

  defp trim(state) do
    if :queue.len(state.order) > @max_entries do
      {{:value, old}, order} = :queue.out(state.order)
      trim(%{state | order: order, entries: Map.delete(state.entries, old)})
    else
      state
    end
  end

  defp reg_name(name) when is_atom(name) and name not in [nil, :undefined, :""], do: name
  defp reg_name(_), do: nil

  defp mfa_from({m, f, a}) when is_list(a), do: {m, f, length(a)}
  defp mfa_from({m, f, a}) when is_integer(a), do: {m, f, a}
  defp mfa_from(_), do: {nil, nil, nil}

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:exberly_trace, event}) end)
  end
end
