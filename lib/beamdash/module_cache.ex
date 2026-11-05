defmodule Beamdash.ModuleCache do
  @moduledoc """
  The modules loaded on the target, as `Beamdash.Tracer.module_functions/2`
  lists them, kept by `Beamdash.NodeCache`.
  """

  alias Beamdash.{NodeCache, Target, Tracer}

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    tracer = Keyword.get(opts, :tracer, Tracer)

    NodeCache.start_link(
      name: Keyword.get(opts, :name, __MODULE__),
      target: Keyword.get(opts, :target, Target),
      fetch: fn _node, timeout -> Tracer.module_functions(tracer, timeout) end
    )
  end

  @doc "The loaded modules, `{:ok, [{mod, exports, locals}]}`, or the error of the fetch."
  def modules(server \\ __MODULE__), do: NodeCache.get(server)
end
