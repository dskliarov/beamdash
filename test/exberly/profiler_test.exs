defmodule Exberly.ProfilerTest do
  use ExUnit.Case, async: false

  alias Exberly.{Profiler, Target}
  alias Exberly.Test.Fixture

  describe "parse_patterns/1" do
    test "Erlang and Elixir forms, wildcards and lists" do
      assert {:ok, [{:_, :_, :_}]} = Profiler.parse_patterns("_")
      assert {:ok, [{:lists, :_, :_}]} = Profiler.parse_patterns("lists")
      assert {:ok, [{:lists, :seq, :_}]} = Profiler.parse_patterns("lists:seq")
      assert {:ok, [{:lists, :seq, 2}]} = Profiler.parse_patterns("lists:seq/2")
      assert {:ok, [{:lists, :_, 2}]} = Profiler.parse_patterns("lists:_/2")
      assert {:ok, [{Enum, :map, 2}]} = Profiler.parse_patterns("Enum.map/2")
      assert {:ok, [{Enum, :_, :_}]} = Profiler.parse_patterns("Enum")
      assert {:ok, [{String.Chars, :_, :_}]} = Profiler.parse_patterns("String.Chars")

      assert {:ok, [{:lists, :seq, 2}, {:demo_shop, :_, :_}, {Enum, :map, :_}]} =
               Profiler.parse_patterns("lists:seq/2, demo_shop\nEnum.map")
    end

    test "errors" do
      assert {:error, _} = Profiler.parse_patterns("  ")
      assert {:error, msg} = Profiler.parse_patterns("lists:seq/x")
      assert msg =~ "lists:seq/x"
      assert {:error, _} = Profiler.parse_patterns(":seq")
    end
  end

  describe "on a node" do
    setup do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      id = System.unique_integer([:positive])
      target = start_supervised!({Target, name: :"target_#{id}"}, id: :target)
      prof = start_supervised!({Profiler, name: :"prof_#{id}", target: target}, id: :prof)
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      :ok = Profiler.subscribe(prof)

      otp = :erpc.call(node, :erlang, :system_info, [:otp_release]) |> List.to_integer()
      %{node: node, prof: prof, target: target, otp: otp}
    end

    test "tprof is reported unavailable before OTP 27", ctx do
      if ctx.otp >= 27,
        do: assert({:ok, true} = Profiler.available(ctx.prof)),
        else: assert({:ok, {false, _release}} = Profiler.available(ctx.prof))
    end

    test "call_time profile of a function, then it stops by itself", ctx do
      if ctx.otp < 27, do: throw(:skip_needs_otp_27)

      assert {:ok, info} =
               Profiler.start(
                 %{
                   type: :call_time,
                   patterns: [{:lists, :seq, 2}, {:no_such_module, :x, 1}],
                   processes: :all,
                   seconds: 2
                 },
                 ctx.prof
               )

      assert info.functions == 1
      assert info.unmatched == [{:no_such_module, :x, 1}]

      # work in new processes on the target (no Elixir there: plain MFAs)
      for _ <- 1..20, do: :erpc.call(ctx.node, :erlang, :spawn, [:lists, :seq, [1, 1000]])

      Process.sleep(300)
      :ok = Profiler.snapshot(ctx.prof)
      %{status: :running, result: result} = Profiler.state(ctx.prof)
      assert result.type == :call_time
      assert [%{mfa: {:lists, :seq, 2}, calls: calls}] = result.lines
      assert calls >= 20
      assert result.processes != []

      # finishes on its own after 2 s, keeping the result
      assert_receive {:exberly_profile, %{status: :done}}, 4_000
      %{status: :done, result: %{lines: [_]}} = Profiler.state(ctx.prof)
      assert :undefined = :erpc.call(ctx.node, :erlang, :whereis, [:exberly_tprof])
    catch
      :skip_needs_otp_27 -> :ok
    end

    test "stop now; and the profile ends if exberly goes away", ctx do
      if ctx.otp < 27, do: throw(:skip_needs_otp_27)

      config = %{type: :call_count, patterns: [{:lists, :_, :_}], processes: :all, seconds: 60}
      assert {:ok, _} = Profiler.start(config, ctx.prof)
      assert is_pid(:erpc.call(ctx.node, :erlang, :whereis, [:exberly_tprof]))
      :ok = Profiler.stop(ctx.prof)
      assert %{status: :done} = Profiler.state(ctx.prof)
      assert :undefined = :erpc.call(ctx.node, :erlang, :whereis, [:exberly_tprof])

      # the profiler process dying: the guard on the target stops tprof
      assert {:ok, _} = Profiler.start(config, ctx.prof)
      :ok = stop_supervised(:prof)
      Process.sleep(200)
      assert :undefined = :erpc.call(ctx.node, :erlang, :whereis, [:exberly_tprof])
    catch
      :skip_needs_otp_27 -> :ok
    end
  end
end
