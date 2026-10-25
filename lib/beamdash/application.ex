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
      Beamdash.SeqTracer,
      Beamdash.Crashes,
      Beamdash.Logs,
      Beamdash.SysTracer,
      Beamdash.Profiler,
      BeamdashWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Beamdash.Supervisor)
  end
end
