defmodule Beamdash.CPU do
  @moduledoc false
  alias Beamdash.{AgentLoader, Target}

  def sample(node) do
    with :ok <- AgentLoader.ensure_loaded(node, &Target.rpc/4, :beamdash_cpu),
         {:ok, result} <- Target.rpc(node, :beamdash_cpu, :sample, [], 3_000) do
      result
    end
  end
end
