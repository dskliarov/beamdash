# Target tests need distribution: make sure epmd runs, then make this
# VM a node. The targets are started with :peer (OTP 25+).
System.cmd("epmd", ["-daemon"])

unless Node.alive?() do
  {:ok, _} = Node.start(:"beamdash_test_#{System.unique_integer([:positive])}", :shortnames)
end

# Tests never read or overwrite the real remembered node and cookie.
last_connection_dir =
  Path.join(System.tmp_dir!(), "beamdash_test_#{System.unique_integer([:positive])}")

Application.put_env(
  :beamdash,
  :last_connection_file,
  Path.join(last_connection_dir, "last_connection.json")
)

Beamdash.LastConnection.reload()

# Nor the real saved settings (the kubeconfig directory).
Application.put_env(:beamdash, :settings_file, Path.join(last_connection_dir, "settings.json"))
Beamdash.Settings.reload()

# Nor the real plugins (config/config.exs points :plugins_dir at a temp dir,
# since the app reads it at startup).
plugins_dir = Beamdash.Plugins.Build.plugins_dir()
true = String.starts_with?(plugins_dir, System.tmp_dir!())

ExUnit.after_suite(fn _ ->
  File.rm_rf(last_connection_dir)
  File.rm_rf(plugins_dir)
end)

# The riak_core plugin's integration test needs the sibling checkout
# ../beamdash-riak-core-plugin: run it with `mix test --only riak_core_plugin`.
ExUnit.configure(exclude: [:riak_core_plugin])

ExUnit.start()
