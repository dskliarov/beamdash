defmodule Beamdash.AppCache do
  @moduledoc """
  The applications running on the target, as `Beamdash.Apps.list/2` lists
  them, kept by `Beamdash.NodeCache`, so the Applications tab does not wait
  for the node on every refresh.
  """

  alias Beamdash.{Apps, NodeCache, Target}

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    NodeCache.start_link(
      name: Keyword.get(opts, :name, __MODULE__),
      target: Keyword.get(opts, :target, Target),
      fetch: &Apps.list/2
    )
  end

  @doc "The applications, `{:ok, [%{name, description, vsn, master}]}`, or the error of the fetch."
  def apps(server \\ __MODULE__), do: NodeCache.get(server)
end
