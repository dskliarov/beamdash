defmodule Exberly.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:exberly, :has_k8s, System.find_executable("kubectl") != nil)

    children = [
      {Phoenix.PubSub, name: Exberly.PubSub},
      Exberly.Target,
      Exberly.Tracer,
      Exberly.SeqTracer,
      Exberly.Crashes,
      Exberly.SysTracer,
      Exberly.Profiler,
      ExberlyWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Exberly.Supervisor)
  end
end
