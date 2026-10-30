defmodule Beamdash.CPUTest do
  use ExUnit.Case, async: false

  test "takes a bounded sample and cleans up its isolated trace session" do
    if Code.ensure_loaded?(:trace) do
      before = :trace.session_info(:all)
      assert {:ok, percentages} = :beamdash_cpu.sample()
      assert is_map(percentages)
      assert Enum.all?(percentages, fn {pid, pct} -> is_pid(pid) and pct >= 0 and pct <= 100 end)
      assert :trace.session_info(:all) == before
    end
  end

  test "reports zero for a process that stays idle through the sample" do
    if Code.ensure_loaded?(:trace) do
      idle = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(idle, :kill) end)
      assert {:ok, values} = :beamdash_cpu.sample()
      assert Map.fetch!(values, idle) == 0.0
    end
  end

  test "measures a busy process and preserves other trace sessions" do
    if Code.ensure_loaded?(:trace) do
      burner = spawn(fn -> burn() end)
      on_exit(fn -> Process.exit(burner, :kill) end)
      observer = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(observer, :kill) end)
      other = :trace.session_create(:beamdash_cpu_test, self(), [])

      try do
        assert 1 == :trace.process(other, observer, true, [:send])
        assert {:ok, values} = Beamdash.CPU.sample(node())
        assert Map.get(values, burner, 0) > 0
        assert other |> elem(1) |> then(&(&1 in :trace.session_info(:all)))
        assert {:flags, flags} = :trace.info(other, observer, :flags)
        assert :send in flags
      after
        :trace.session_destroy(other)
      end
    end
  end

  test "only one CPU sample may run on the target at a time" do
    if Code.ensure_loaded?(:trace) do
      Process.register(self(), :beamdash_cpu_sampler)
      assert {:error, :busy} = :beamdash_cpu.sample()
    end
  end

  test "samples a connected remote node" do
    {peer, node} = Beamdash.Test.Fixture.start_peer()
    on_exit(fn -> Beamdash.Test.Fixture.stop_peer(peer) end)

    assert {:ok, _} =
             Beamdash.Target.connect(Atom.to_string(node), Beamdash.Test.Fixture.cookie())

    on_exit(fn -> Beamdash.Target.disconnect() end)

    if Code.ensure_loaded?(:trace) do
      assert {:ok, values} = Beamdash.CPU.sample(node)
      assert is_map(values)
    end
  end

  defp burn do
    :erlang.phash2({self(), 1})
    burn()
  end
end
