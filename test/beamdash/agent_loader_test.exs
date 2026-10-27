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

  test "loads this machine's BEAM when the target accepts it" do
    rpc = fn
      _node, :beamdash_agent, :module_info, [:md5] -> {:error, :undef}
      _node, :code, :load_binary, [mod, _file, _bin] -> {:ok, {:module, mod}}
    end

    assert :ok = AgentLoader.ensure_loaded(:target@host, rpc)
  end

  test "recompiles here for an older target release, no compiler needed there",
       %{local_bin: local_bin} do
    assert :ok = AgentLoader.ensure_loaded(:target@host, old_target(self(), local_bin))

    assert_received {:loaded, :local}
    assert_received {:loaded, release_bin}
    assert release_bin != local_bin
  end

  test "does not reload a module already recompiled for the target", %{local_bin: local_bin} do
    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(local_bin, [:abstract_code])

    {:ok, _, release_bin} = :compile.forms(forms, [:binary, :return_errors, :r26])
    {:ok, {_, md5}} = :beam_lib.md5(release_bin)

    assert :ok = AgentLoader.ensure_loaded(:target@host, old_target(self(), local_bin, md5))

    assert_received {:loaded, :local}
    refute_received {:loaded, _}
  end
end
