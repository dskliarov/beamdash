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

  test "a burst of trace events aborts sampling and releases the trace session" do
    if Code.ensure_loaded?(:trace) do
      before = :trace.session_info(:all)
      task = Task.async(fn -> :beamdash_cpu.sample() end)
      sampler = await_sampler(100)
      timestamp = System.monotonic_time(:nanosecond)
      event = {:trace_ts, self(), :in, :unknown, timestamp}
      for _ <- 1..70_000, do: send(sampler, event)
      assert {:error, :overloaded} = Task.await(task, 3_000)
      assert :trace.session_info(:all) == before
    end
  end

  defp await_sampler(0), do: flunk("CPU sampler did not start")

  defp await_sampler(attempts) do
    case Process.whereis(:beamdash_cpu_sampler) do
      nil ->
        Process.sleep(2)
        await_sampler(attempts - 1)

      pid ->
        pid
    end
  end

  test "an unmatched scheduling-out event marks that process as unknown" do
    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(:code.which(:beamdash_cpu), [:abstract_code])

    module = :beamdash_cpu_accounting_test

    forms =
      Enum.flat_map(forms, fn
        {:attribute, line, :module, :beamdash_cpu} ->
          [{:attribute, line, :module, module}, {:attribute, line, :export, [add_time: 5]}]

        form ->
          [form]
      end)

    assert {:ok, ^module, binary} = :compile.forms(forms, [:binary])
    assert {:module, ^module} = :code.load_binary(module, ~c"accounting_test", binary)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    pid = self()
    {running, totals} = apply(module, :add_time, [pid, 50, 100, %{}, %{}])
    assert totals[pid] == :unknown
    {_, totals} = apply(module, :add_time, [pid, 90, 100, Map.put(running, pid, 70), totals])
    assert totals[pid] == :unknown
  end

  test "stopping an active boundary scanner does not kill its linked sampler" do
    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(:code.which(:beamdash_cpu), [:abstract_code])

    module = :beamdash_cpu_scanner_test

    forms =
      Enum.flat_map(forms, fn
        {:attribute, line, :module, :beamdash_cpu} ->
          [{:attribute, line, :module, module}, {:attribute, line, :export, [stop_scanner: 1]}]

        form ->
          [form]
      end)

    assert {:ok, ^module, binary} = :compile.forms(forms, [:binary])
    assert {:module, ^module} = :code.load_binary(module, ~c"scanner_test", binary)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    previous = Process.flag(:trap_exit, true)
    scanner = spawn_link(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(scanner)
    apply(module, :stop_scanner, [scanner])
    assert_receive {:DOWN, ^monitor, :process, ^scanner, :killed}
    refute_receive {:EXIT, ^scanner, :killed}, 100
    Process.flag(:trap_exit, previous)
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

  test "does not report an unobserved running native operation as idle" do
    if Code.ensure_loaded?(:trace) do
      owner = self()

      pid =
        spawn(fn ->
          send(owner, :native_started)
          :crypto.pbkdf2_hmac(:sha256, "secret", "salt", 10_000_000, 32)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive :native_started
      Process.sleep(50)
      assert Process.info(pid, :status) == {:status, :running}
      assert {:ok, values} = Beamdash.CPU.sample(node())
      assert Process.info(pid, :status) == {:status, :running}
      refute Map.get(values, pid) == 0.0
    end
  end

  defp burn do
    :erlang.phash2({self(), 1})
    burn()
  end
end
