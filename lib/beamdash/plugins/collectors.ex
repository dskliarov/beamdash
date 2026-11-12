defmodule Beamdash.Plugins.Collectors do
  @moduledoc """
  Runs the active plugins' collectors (the `:collectors` option of
  `use Beamdash.Plugin`) while a node is attached. It starts with the event
  store, so collectors don't run while storing is off.

  Each collector `{module, fun}` is called as `module.fun(state)`. `state`
  is `nil` at first, then what the previous call returned as `{:ok,
  state}`. Anything else, a raise, or a call that takes longer than the
  collector's interval (at most 60 s) keeps the previous state, and is
  logged when it differs from the collector's previous failure. A call runs
  in a task under `Beamdash.Plugins.TaskSup`; the next call of the same
  collector starts its interval after the previous one ended.

  A connection to another node (or none) drops every state and stops the
  calls still running, as does a plugin that stops being active for its
  collectors, so no state ever spans two nodes.
  """
  use GenServer
  require Logger

  alias Beamdash.{Plugin, Plugins, Target}

  @tick 1_000
  @max_timeout 60_000

  defstruct plugins: Plugins,
            target: Target,
            task_sup: Beamdash.Plugins.TaskSup,
            tick: @tick,
            node: nil,
            # {app, name} => %{state, next_at, task: nil | %{ref, pid, deadline}, error}
            entries: %{}

  @doc """
  Options: `name:`, `plugins:` (the `Beamdash.Plugins` server), `target:`,
  `task_sup:` and `tick:` (how often due collectors are looked for, default
  1 s; `:manual` for none, see `tick/1`).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Starts the collectors that are due now."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "The state each collector keeps, as `%{{app, name} => state}`."
  def states(server \\ __MODULE__), do: GenServer.call(server, :states)

  @impl true
  def init(opts) do
    state = struct!(__MODULE__, Keyword.take(opts, [:plugins, :target, :task_sup, :tick]))
    schedule(state.tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, run(state)}

  def handle_call(:states, _from, state),
    do: {:reply, Map.new(state.entries, fn {key, e} -> {key, e.state} end), state}

  @impl true
  def handle_info(:tick, state) do
    state = run(state)
    schedule(state.tick)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case find(state, ref) do
      nil ->
        {:noreply, state}

      key ->
        Process.demonitor(ref, [:flush])
        {:noreply, finished(state, key, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find(state, ref) do
      nil -> {:noreply, state}
      key -> {:noreply, finished(state, key, {:crashed, reason})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(:manual), do: :ok
  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp run(state) do
    node = Plugin.__current_node__(state.target)

    state =
      if node != state.node,
        do: %{drop(state, Map.keys(state.entries)) | node: node},
        else: state

    with true <- node != nil,
         {:ok, active} <- active(state.plugins) do
      state = drop(state, Map.keys(state.entries) -- Map.keys(active))
      now = now()

      Enum.reduce(active, state, fn {key, collector}, state ->
        entry = Map.get(state.entries, key, %{state: nil, next_at: now, task: nil, error: nil})
        put_in(state.entries[key], step(state, key, collector, entry, now))
      end)
    else
      _ -> state
    end
  end

  # One collector at `now`: kill a call past its deadline, or start a due one.
  defp step(_state, key, collector, %{task: %{deadline: deadline} = task} = entry, now)
       when now >= deadline do
    stop(task)
    failed(key, entry, "did not answer in #{div(timeout(collector), 1000)} s", collector, now)
  end

  defp step(_state, _key, _collector, %{task: %{}} = entry, _now), do: entry

  defp step(state, _key, collector, %{next_at: next_at} = entry, now) when now >= next_at do
    {mod, fun} = collector.call
    previous = entry.state
    task = Task.Supervisor.async_nolink(state.task_sup, fn -> apply(mod, fun, [previous]) end)

    %{
      entry
      | task: %{
          ref: task.ref,
          pid: task.pid,
          deadline: now + timeout(collector),
          collector: collector
        }
    }
  end

  defp step(_state, _key, _collector, entry, _now), do: entry

  defp finished(state, key, result) do
    entry = state.entries[key]
    collector = entry.task.collector
    now = now()

    entry =
      case result do
        {:ok, new} ->
          %{entry | state: new, task: nil, error: nil, next_at: now + collector.interval}

        {:crashed, reason} ->
          failed(key, entry, "crashed: #{Exception.format_exit(reason)}", collector, now)

        other ->
          failed(key, entry, "returned #{inspect(other, limit: 10)}", collector, now)
      end

    put_in(state.entries[key], entry)
  end

  defp failed({app, name}, entry, message, collector, now) do
    if message != entry.error,
      do: Logger.warning("plugin #{app}: collector #{inspect(name)} #{message}")

    %{entry | task: nil, error: message, next_at: now + collector.interval}
  end

  defp drop(state, keys) do
    for key <- keys, %{task: %{} = task} <- [state.entries[key]], do: stop(task)
    %{state | entries: Map.drop(state.entries, keys)}
  end

  defp stop(%{ref: ref, pid: pid}) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
  end

  defp find(state, ref) do
    Enum.find_value(state.entries, fn
      {key, %{task: %{ref: ^ref}}} -> key
      _ -> nil
    end)
  end

  defp active(plugins) do
    active =
      for %{app: app} = plugin <- Plugins.active(plugins),
          collector <- Map.get(plugin, :collectors, []),
          into: %{},
          do: {{app, collector.name}, collector}

    {:ok, active}
  catch
    # Plugins busy (or restarting): the states are kept, for the next tick
    :exit, _ -> :error
  end

  defp timeout(collector), do: min(collector.interval, @max_timeout)

  defp now, do: System.monotonic_time(:millisecond)
end
