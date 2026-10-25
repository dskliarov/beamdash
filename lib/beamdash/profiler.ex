defmodule Beamdash.Profiler do
  @moduledoc """
  Profiling on the connected node with OTP's `tprof` (OTP 27+), through
  `beamdash_agent:tprof_*`.

  One profile runs at a time. It measures one of

    * `:call_count` – how often each function is called (by any process),
    * `:call_time` – time spent in each function (µs), or
    * `:call_memory` – heap allocated by each function (words),

  for the functions matching the given patterns, in the chosen processes,
  for a set number of seconds; then it stops by itself and keeps the
  result. While it runs, results are collected every couple of seconds
  (when few enough functions are traced for that to be cheap).

  This process is the profile's owner on the target: if it goes away, the
  agent stops profiling there.

  Subscribers receive `{:beamdash_profile, state}` on every change.
  """

  use GenServer

  alias Beamdash.Target

  @refresh_ms 2_000
  # above this many traced functions, results are only collected on request
  @auto_refresh_max 2_000
  @rpc_timeout 30_000

  defstruct target: Target,
            node: nil,
            status: :idle,
            config: nil,
            started_at: nil,
            duration_ms: nil,
            info: nil,
            result: nil,
            error: nil,
            timer: nil,
            run: nil,
            subscribers: %{}

  ## API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "`{:ok, true}` if the target has tprof, `{:ok, {false, otp_release}}` if not."
  def available(server \\ __MODULE__), do: GenServer.call(server, :available, @rpc_timeout)

  @doc """
  Starts profiling. `config` is a map with `:type`, `:patterns`
  (`[{mod, fun, arity}]`, `:_` for any), `:processes` (`:all`, `:new`,
  `:existing` or a list of pids and registered names) and `:seconds`.
  """
  def start(config, server \\ __MODULE__),
    do: GenServer.call(server, {:start, config}, @rpc_timeout)

  @doc "Stops the running profile now and keeps its result."
  def stop(server \\ __MODULE__), do: GenServer.call(server, :stop, @rpc_timeout)

  @doc "Collects the result so far without stopping."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot, @rpc_timeout)

  def state(server \\ __MODULE__), do: GenServer.call(server, :state)
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc """
  Parses function patterns as typed: one per line or comma, each

    * `_` – every function in every module
    * `mod`, `mod:fun`, `mod:fun/arity` (Erlang), or
    * `Mod`, `Mod.fun`, `Mod.fun/arity` (Elixir module names),

  with `_` for any part. Returns `{:ok, [{mod, fun, arity}]}` or
  `{:error, message}`.
  """
  def parse_patterns(text) do
    text
    |> String.split(~r/[\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] ->
        {:error, "Enter at least one module or function, e.g. lists:seq/2 (or _ for everything)."}

      items ->
        Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
          case parse_pattern(item) do
            {:ok, p} ->
              {:cont, {:ok, acc ++ [p]}}

            :error ->
              {:halt, {:error, "Cannot read “#{item}”: use mod, mod:fun or mod:fun/arity."}}
          end
        end)
    end
  end

  defp parse_pattern(item) when item in ["_", "*"], do: {:ok, {:_, :_, :_}}

  defp parse_pattern(item) do
    {name, arity} =
      case String.split(item, "/", parts: 2) do
        [name, a] -> {name, a}
        [name] -> {name, "_"}
      end

    with {:ok, arity} <- parse_arity(arity),
         {:ok, mod, fun} <- split_mod_fun(name) do
      {:ok, {mod, fun, arity}}
    end
  end

  defp parse_arity("_"), do: {:ok, :_}

  defp parse_arity(a) do
    case Integer.parse(a) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  # Erlang "mod:fun"; Elixir "Mod.Sub.fun" (a lowercase last part is the
  # function) or "Mod.Sub".
  defp split_mod_fun(name) do
    cond do
      name == "" ->
        :error

      String.contains?(name, ":") ->
        case String.split(name, ":", parts: 2) do
          [m, f] when m != "" and f != "" -> {:ok, atom(m), atom(f)}
          _ -> :error
        end

      Regex.match?(~r/^[A-Z]/, name) ->
        parts = String.split(name, ".")
        {mods, last} = Enum.split(parts, -1)

        if mods != [] and Regex.match?(~r/^[a-z_]/, hd(last)),
          do: {:ok, elixir_module(mods), atom(hd(last))},
          else: {:ok, elixir_module(parts), :_}

      true ->
        {:ok, atom(name), :_}
    end
  end

  defp elixir_module(parts), do: String.to_atom("Elixir." <> Enum.join(parts, "."))
  defp atom("_"), do: :_
  defp atom(s), do: String.to_atom(s)

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
  def handle_call(:available, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(:available, _from, state),
    do: {:reply, unwrap(Target.rpc(state.node, :beamdash_agent, :tprof_available, [])), state}

  def handle_call({:start, _config}, _from, %{node: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:start, config}, _from, state) do
    state = cancel_timer(state)

    args = [config.type, config.patterns, config.processes, self()]

    case unwrap(Target.rpc(state.node, :beamdash_agent, :tprof_start, args, @rpc_timeout)) do
      {:ok, {:ok, info}} ->
        duration_ms = config.seconds * 1_000
        # tagged with the run, so a timer left from an earlier run is ignored
        run = make_ref()
        Process.send_after(self(), {:finish, run}, duration_ms)

        state = %{
          state
          | status: :running,
            run: run,
            config: config,
            started_at: System.monotonic_time(:millisecond),
            duration_ms: duration_ms,
            info: info,
            result: nil,
            error: nil
        }

        state = schedule_refresh(state)
        notify(state)
        {:reply, {:ok, info}, state}

      {:ok, {:error, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop, _from, %{status: :running} = state) do
    state = finish(state)
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  def handle_call(:snapshot, _from, %{status: :running} = state) do
    state = collect(state)
    notify(state)
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, :ok, state}

  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  @impl true
  def handle_info({:finish, run}, %{status: :running, run: run} = state),
    do: {:noreply, finish(state)}

  def handle_info({:finish, _old_run}, state), do: {:noreply, state}

  def handle_info(:refresh, %{status: :running} = state) do
    state = state |> collect() |> schedule_refresh()
    notify(state)
    {:noreply, state}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:beamdash_target, {:connected, node}}, state) do
    state = %{cancel_timer(state) | node: node, status: :idle, result: nil, info: nil, error: nil}
    notify(state)
    {:noreply, state}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, state) do
    # the agent's guard stops tprof on the target once we are gone
    state = %{cancel_timer(state) | node: nil, status: :idle, result: nil, info: nil}
    notify(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  ## Helpers

  defp finish(state) do
    state = state |> cancel_timer() |> collect()
    _ = Target.rpc(state.node, :beamdash_agent, :tprof_stop, [])
    state = %{state | status: :done}
    notify(state)
    state
  end

  defp collect(state) do
    case unwrap(Target.rpc(state.node, :beamdash_agent, :tprof_collect, [true], @rpc_timeout)) do
      {:ok, {:ok, result}} ->
        %{state | result: Map.put(result, :collected_at, DateTime.utc_now()), error: nil}

      {:ok, {:error, reason}} ->
        %{state | error: reason}

      {:error, reason} ->
        %{state | error: reason}
    end
  end

  defp schedule_refresh(%{info: %{functions: n}} = state)
       when is_integer(n) and n <= @auto_refresh_max,
       do: %{state | timer: Process.send_after(self(), :refresh, @refresh_ms)}

  defp schedule_refresh(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap(other), do: other

  defp public(state) do
    Map.take(state, [:status, :config, :started_at, :duration_ms, :info, :result, :error])
  end

  defp notify(state) do
    pub = public(state)
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:beamdash_profile, pub}) end)
  end
end
