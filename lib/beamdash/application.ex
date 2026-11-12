defmodule Beamdash.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:beamdash, :has_k8s, System.find_executable("kubectl") != nil)

    children = [
      {Phoenix.PubSub, name: Beamdash.PubSub},
      Beamdash.Target,
      Beamdash.Tracer,
      Beamdash.ModuleCache,
      Beamdash.AppCache,
      Beamdash.SeqTracer,
      Beamdash.Crashes,
      Beamdash.Logs,
      {Task.Supervisor, name: Beamdash.Plugins.TaskSup},
      Beamdash.Plugins,
      Beamdash.SysTracer,
      Beamdash.Profiler,
      Beamdash.AnomalyMonitor,
      BeamdashWeb.Endpoint
    ]

    store =
      if Beamdash.Store.path(),
        do: [Beamdash.Store, Beamdash.Sampler, Beamdash.Plugins.Collectors],
        else: []

    Supervisor.start_link(children ++ store, strategy: :one_for_one, name: Beamdash.Supervisor)
  end
end
