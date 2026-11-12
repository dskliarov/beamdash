defmodule Beamdash.AgentLoaderTest do
  use ExUnit.Case, async: true

  alias Beamdash.AgentLoader

  # A target on an older OTP with no compiler application: it refuses this
  # machine's BEAM and has no compile:forms/2. `loaded` is the md5 the
  # target reports for the module, and every binary it loads goes to `test`.
  defp old_target(test, local_bin, loaded \\ nil) do
    fn
      _node, :beamdash_agent, :module_info, [:md5] ->
        if loaded, do: {:ok, loaded}, else: {:error, :undef}

      _node, :code, :load_binary, [_mod, _file, ^local_bin] ->
        send(test, {:loaded, :local})
        {:ok, {:error, :badfile}}

      _node, :code, :load_binary, [mod, _file, bin] ->
        send(test, {:loaded, bin})
        {:ok, {:module, mod}}

      _node, :erlang, :system_info, [:otp_release] ->
        {:ok, ~c"26"}

      _node, :compile, :forms, _args ->
        {:error, {:exception, :undef, []}}
    end
  end

  setup do
    {:beamdash_agent, bin, _file} = :code.get_object_code(:beamdash_agent)
    %{local_bin: bin}
  end

  test "loads this machine's BEAM on a target of the same release", %{local_bin: local_bin} do
    test = self()

    rpc = fn
      _node, :beamdash_agent, :module_info, [:md5] ->
        {:error, :undef}

      _node, :erlang, :system_info, [:otp_release] ->
        {:ok, :erlang.system_info(:otp_release)}

      _node, :code, :load_binary, [mod, _file, bin] ->
        send(test, {:loaded, bin})
        {:ok, {:module, mod}}
    end

    assert :ok = AgentLoader.ensure_loaded(:target@host, rpc)
    assert_received {:loaded, ^local_bin}
  end

  test "recompiles here for an older target release before sending anything, no compiler needed there",
       %{local_bin: local_bin} do
    assert :ok = AgentLoader.ensure_loaded(:target@host, old_target(self(), local_bin))

    # never this machine's BEAM, which the target would refuse and log
    refute_received {:loaded, :local}
    assert_received {:loaded, release_bin}
    assert release_bin != local_bin
  end

  test "a target that refuses the BEAM and has no release option compiles it itself",
       %{local_bin: local_bin} do
    test = self()

    rpc = fn
      _node, :beamdash_agent, :module_info, [:md5] ->
        {:error, :undef}

      _node, :erlang, :system_info, [:otp_release] ->
        {:ok, ~c"24"}

      _node, :code, :load_binary, [_mod, _file, ^local_bin] ->
        {:ok, {:error, :badfile}}

      _node, :compile, :forms, [_forms, _opts] ->
        send(test, :compiled_there)
        {:ok, {:ok, :beamdash_agent, "remote"}}

      _node, :code, :load_binary, [mod, _file, "remote"] ->
        {:ok, {:module, mod}}
    end

    assert :ok = AgentLoader.ensure_loaded(:target@host, rpc)
    assert_received :compiled_there
  end

  test "does not reload a module already recompiled for the target", %{local_bin: local_bin} do
    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(local_bin, [:abstract_code])

    {:ok, _, release_bin} = :compile.forms(forms, [:binary, :return_errors, :r26])
    {:ok, {_, md5}} = :beam_lib.md5(release_bin)

    assert :ok = AgentLoader.ensure_loaded(:target@host, old_target(self(), local_bin, md5))

    refute_received {:loaded, _}
  end
end
