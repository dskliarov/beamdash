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

ExUnit.after_suite(fn _ -> File.rm_rf(last_connection_dir) end)
ExUnit.start()
