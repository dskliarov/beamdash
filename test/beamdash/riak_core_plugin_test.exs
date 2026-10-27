defmodule Beamdash.RiakCorePluginTest do
  # Installs the riak_core plugin from its sibling checkout
  # (../beamdash-riak-core-plugin) with Beamdash.Plugins. Excluded by default
  # (test_helper.exs); run it with `mix test --only riak_core_plugin`.
  use ExUnit.Case, async: false

  alias Beamdash.{Plugins, Target}
  alias Beamdash.Plugins.Build

  @moduletag :riak_core_plugin
  @moduletag :capture_log

  @plugin_src Path.expand("../../../beamdash-riak-core-plugin", __DIR__)
  @modules [
    RiakCorePlugin,
    RiakCorePlugin.Components,
    RiakCorePlugin.Data,
    RiakCorePlugin.Riak,
    RiakCorePlugin.RingChart,
    RiakCorePlugin.RingLive,
    RiakCorePlugin.MembersLive,
    RiakCorePlugin.VnodesLive,
    RiakCorePlugin.HandoffsLive,
    RiakCorePlugin.AdminLive
  ]

  # compiled and loaded at runtime
  @compile {:no_warn_undefined, @modules}

  setup do
    unless File.exists?(Path.join(@plugin_src, "mix.exs")),
      do: flunk("the riak_core plugin checkout is missing: #{@plugin_src}")

    base = Path.join(System.tmp_dir!(), "beamdash_rcp_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "plugins")
    File.mkdir_p!(dir)

    old = Application.fetch_env(:beamdash, :plugins_dir)
    Application.put_env(:beamdash, :plugins_dir, dir)

    on_exit(fn ->
      Build.unload(@modules)

      case old do
        {:ok, v} -> Application.put_env(:beamdash, :plugins_dir, v)
        :error -> Application.delete_env(:beamdash, :plugins_dir)
      end

      File.rm_rf(base)
    end)

    %{dir: dir}
  end

  test "installs by path: five pages, supports riak_core ~> 0.10", %{dir: dir} do
    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"rcp_target_#{id}"}, id: :"target_#{id}")

    server =
      start_supervised!({Plugins, name: :"rcp_plugins_#{id}", dir: dir, target: target},
        id: :"plugins_#{id}"
      )

    {:ok, ref} = Plugins.install(server, ~s|{:riak_core_plugin, path: "#{@plugin_src}"}|)

    # either outcome, so a failed install prints its message
    assert_receive {:beamdash_plugins, {outcome, ^ref, payload}}
                   when outcome in [:installed, :install_failed],
                   60_000

    assert {outcome, payload} == {:installed, :riak_core_plugin}

    entry = Enum.find(Plugins.list(server), &(&1.app == :riak_core_plugin))

    assert %{source: :path, plugin: %{name: "riak_core", pages: pages}, status: :waiting} = entry
    assert entry.supports == [{:riak_core, "~> 0.10"}]
    assert Enum.map(pages, & &1.slug) == ["ring", "members", "vnodes", "handoffs", "admin"]
    assert Enum.sort(entry.modules) == Enum.sort(@modules)

    assert length(RiakCorePlugin.__beamdash_plugin__().pages) == 5
    # loaded from the plugin's ebin, and it runs here: no riak_core attached
    assert RiakCorePlugin.Data.error_message(:not_connected) == "no node is attached"
    assert RiakCorePlugin.Riak.ring(target) == {:error, "no node is attached"}
  end
end
