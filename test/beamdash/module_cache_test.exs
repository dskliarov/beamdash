defmodule Beamdash.ModuleCacheTest do
  use ExUnit.Case, async: false

  alias Beamdash.{ModuleCache, Target, Tracer}

  @cookie "beamdash_test_cookie"

  setup do
    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(),
        args: [~c"-setcookie", String.to_charlist(@cookie)],
        connection: :standard_io
      })

    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"cache_target_#{id}"}, id: :target)
    tracer = start_supervised!({Tracer, name: :"cache_tracer_#{id}", target: target}, id: :tracer)

    cache =
      start_supervised!(
        {ModuleCache, name: :"cache_#{id}", target: target, tracer: tracer},
        id: :cache
      )

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    %{node: node, target: target, cache: cache}
  end

  test "reports not connected until the target connects", ctx do
    assert ModuleCache.modules(ctx.cache) == {:error, :not_connected}
  end

  test "fetches the node's loaded modules once the target connects", ctx do
    {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.target)

    assert {:ok, mods} = ModuleCache.modules(ctx.cache)
    assert List.keymember?(mods, :lists, 0)
  end
end
