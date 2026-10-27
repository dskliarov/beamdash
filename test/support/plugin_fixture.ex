defmodule Beamdash.Test.PluginFixture do
  @moduledoc false
  # The hello fixture plugin (test/fixtures/plugins/hello_plugin) and the
  # `:hello_app` application it supports, started on a peer node.

  @fixture Path.expand("../fixtures/plugins/hello_plugin", __DIR__)

  def fixture, do: @fixture

  @doc "Copies the fixture to `<base>/<name>` and returns that path."
  def copy_fixture(base, name \\ "hello") do
    src = Path.join(base, name)
    File.mkdir_p!(src)
    File.cp_r!(@fixture, src)
    src
  end

  @doc "Loads and starts an empty `:hello_app` of version `vsn` on `node`."
  def start_app(node, vsn) do
    :ok = :erpc.call(node, :application, :load, [hello_app(vsn)])
    :ok = :erpc.call(node, :application, :start, [:hello_app])
  end

  def stop_app(node) do
    :ok = :erpc.call(node, :application, :stop, [:hello_app])
    :ok = :erpc.call(node, :application, :unload, [:hello_app])
  end

  defp hello_app(vsn) do
    {:application, :hello_app,
     [
       description: ~c"t",
       vsn: String.to_charlist(vsn),
       modules: [],
       registered: [],
       applications: [:kernel, :stdlib]
     ]}
  end
end
