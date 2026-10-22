defmodule Beamdash.Crashes do
  @moduledoc """
  Crash reports from the target, through erlyberly's error_logger handler.

  On connect, `erlyberly` is installed as an error_logger report handler on
  the target with this process as its destination, so every crash report
  (a proc_lib process – gen_server, supervisor child, Task ... – dying
  abnormally) is sent here as `{erlyberly_error_report, props}`.
  `Beamdash.Target` removes the handler again on disconnect.

  Subscribers receive `{:beamdash_crash, crash}` and
  `{:beamdash_crash, :cleared}`.
  """

  use GenServer

  alias Beamdash.{Record, Target}

  @max_reports 500

  defstruct target: Target, node: nil, reports: [], next_id: 1, subscribers: %{}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Reports, newest first."
  def reports(server \\ __MODULE__), do: GenServer.call(server, :reports)
  def report(id, server \\ __MODULE__), do: GenServer.call(server, {:report, id})
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  ## GenServer

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target, Target)
    :ok = Target.subscribe(target)
    state = %__MODULE__{target: target}

    case Target.status(target) do
      %{status: :connected, node: node} -> {:ok, install(%{state | node: node})}
      _ -> {:ok, state}
    end
  end

  @impl true
  def handle_call(:reports, _from, state), do: {:reply, state.reports, state}

  def handle_call({:report, id}, _from, state),
    do: {:reply, Enum.find(state.reports, &(&1.id == id)), state}

  def handle_call(:clear, _from, state) do
    notify(state, :cleared)
    {:reply, :ok, %{state | reports: []}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  @impl true
  def handle_info({:erlyberly_error_report, props}, state) do
    crash = to_crash(props, state.next_id)
    notify(state, crash)
    reports = Enum.take([crash | state.reports], @max_reports)
    {:noreply, %{state | reports: reports, next_id: state.next_id + 1}}
  end

  def handle_info({:beamdash_target, {:connected, node}}, state),
    do: {:noreply, install(%{state | node: node})}

  def handle_info({:beamdash_target, {:disconnected, _}}, state),
    do: {:noreply, %{state | node: nil}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  ## Helpers

  # Replace any handler left by an earlier session (it would point at a
  # pid that no longer exists), then add ours.
  defp install(state) do
    Target.rpc(state.node, :error_logger, :delete_report_handler, [:erlyberly])
    Target.rpc(state.node, :error_logger, :add_report_handler, [:erlyberly, [self()]])
    state
  end

  defp to_crash(props, id) do
    {class, reason, stack} =
      case props[:error_info] do
        {c, r, s} when is_list(s) -> {c, r, s}
        other -> {:exit, other, []}
      end

    %{
      id: id,
      at: DateTime.utc_now(),
      pid: props[:pid],
      registered_name: registered_name(props[:registered_name]),
      initial_call: props[:initial_call],
      class: class,
      reason: Record.decode(reason),
      stack: stack,
      props: Enum.reject(props, fn {k, _} -> k in [:error_info] end)
    }
  end

  defp registered_name(name) when is_atom(name) and name not in [nil, :undefined], do: name
  defp registered_name(_), do: nil

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:beamdash_crash, event}) end)
  end
end
