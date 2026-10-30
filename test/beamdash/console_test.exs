defmodule Beamdash.ConsoleTest do
  use ExUnit.Case, async: false
  alias Beamdash.Console
  alias Beamdash.Test.Fixture

  test "evaluates on the target, retains bindings, and captures output" do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)
    {:ok, _} = Beamdash.Target.connect(Atom.to_string(node), Fixture.cookie())
    on_exit(fn -> Beamdash.Target.disconnect() end)
    assert Enum.any?(Console.complete(node, :erlang, "lists:ma"), &(&1.insert == "lists:map("))
    assert {:ok, session} = Console.start(node, self(), :erlang)
    assert {:ok, %{status: :ok}} = Console.eval(node, session, "X = 21.")

    assert {:ok, %{status: :ok, result: "42", output: "hello\n"}} =
             Console.eval(node, session, "io:format(\"hello~n\"), X * 2.")

    assert {:ok, %{result: result}} = Console.eval(node, session, "node().")
    assert result =~ Atom.to_string(node)
    assert {:ok, %{status: :error}} = Console.eval(node, session, "error(bad_command).")
    assert {:ok, %{result: "21"}} = Console.eval(node, session, "X.")
    Console.stop(session)
  end

  test "Elixir evaluation preserves bindings" do
    assert {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)
    assert {:ok, %{status: :ok}} = Console.eval(node(), session, "x = 7")

    assert {:ok, %{result: "14", output: "hello\n"}} =
             Console.eval(node(), session, "IO.puts(\"hello\"); x * 2")
  end

  test "Erlang REPL waits for a period without evaluating partial input" do
    {:ok, session} = Console.start(node(), self(), :erlang)
    on_exit(fn -> Console.stop(session) end)
    assert {:ok, %{status: :incomplete, output: ""}} = Console.submit(node(), session, "X = 21")
    assert {:ok, %{status: :ok, result: "21"}} = Console.submit(node(), session, "X = 21\n.")
    assert {:ok, %{status: :incomplete}} = Console.submit(node(), session, "\"a dot.\"")
    assert {:ok, %{status: :ok, result: "42"}} = Console.submit(node(), session, "X * 2.")
    assert {:ok, %{status: :error}} = Console.submit(node(), session, "[1, .")
    assert {:ok, %{result: "21"}} = Console.submit(node(), session, "X.")
  end

  test "formats nested Erlang terms over readable lines" do
    {:ok, session} = Console.start(node(), self(), :erlang)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{status: :ok, result: result}} =
             Console.eval(
               node(),
               session,
               ~S|#{alpha => lists:seq(1000, 1017), beta => #{nested => ok}}.|
             )

    assert result =~ "\n"
    assert result =~ "alpha"
    assert result =~ "nested"
    assert Enum.all?(String.split(result, "\n"), &(String.length(&1) <= 60))
  end

  test "renders successful results as styled code and escapes their contents" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ConsoleLive.mount(%{}, %{}, socket)

    entry = %{
      id: make_ref(),
      number: 1,
      command: "test.",
      language: :erlang,
      status: :ok,
      result: ~S(#{value => <<"<tag>">>}),
      output: ""
    }

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        status: :connected,
        node: :remote@host,
        entries: [entry]
      )

    html =
      socket.assigns
      |> Map.put(:socket, socket)
      |> BeamdashWeb.ConsoleLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "console-result"
    assert html =~ "language-erlang"
    assert html =~ "&lt;tag&gt;"
    refute html =~ "<tag>"
  end

  test "Elixir REPL continues blocks, operators and strings and preserves its environment" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    for code <- ["if true do", "Enum.map([1], fn x ->", "[1,", "1 +", ~s(\"hello)] do
      assert {:ok, %{status: :incomplete, output: ""}} = Console.submit(node(), session, code)
    end

    assert {:ok, %{status: :ok, result: "42"}} =
             Console.submit(node(), session, "x = if true do\n  42\nend")

    assert {:ok, %{status: :error}} = Console.submit(node(), session, "if )")
    assert {:ok, %{result: "42"}} = Console.submit(node(), session, "x")
  end

  test "incomplete REPL input restores the draft and does not consume a prompt number" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ConsoleLive.mount(%{}, %{}, socket)
    ref = make_ref()

    entry = %{
      id: ref,
      number: 1,
      command: "if true do",
      language: :elixir,
      status: :running,
      result: "",
      output: ""
    }

    socket = Phoenix.Component.assign(socket, pending: ref, counter: 2, entries: [entry])

    {:noreply, socket} =
      BeamdashWeb.ConsoleLive.handle_async(
        {:evaluate, ref},
        {:ok, {:ok, %{status: :incomplete, result: "", output: ""}}},
        socket
      )

    assert socket.assigns.command == "if true do\n"
    assert socket.assigns.continuation
    assert socket.assigns.counter == 1
    assert socket.assigns.entries == []
    assert socket.assigns.pending == nil
  end

  test "sessions stop when their owner exits" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, session} = Console.start(node(), owner, :erlang)
    ref = Process.monitor(session)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 1000
  end

  test "output is bounded and interactive input returns an error" do
    {:ok, session} = Console.start(node(), self(), :erlang)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{output: output}} =
             Console.eval(node(), session, "io:put_chars(lists:duplicate(70000, $x)).")

    assert byte_size(output) <= 64000
    assert {:ok, %{result: result}} = Console.eval(node(), session, "io:get_line(\"prompt\").")
    assert result =~ "error"
  end

  test "a timeout resets the evaluator and permits the next command" do
    {:ok, session} = Console.start(node(), self(), :erlang)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{status: :error, result: result}} =
             Console.eval(node(), session, "receive never -> ok end.")

    assert result =~ "timed out"
    assert {:ok, %{result: "2"}} = Console.eval(node(), session, "1 + 1.")
  end

  test "console view shows the target and ignores results from an old session" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ConsoleLive.mount(%{}, %{}, socket)

    socket =
      Phoenix.Component.assign(socket, syntax: :erlang, status: :connected, node: :remote@host)

    html =
      socket.assigns
      |> Map.put(:socket, socket)
      |> BeamdashWeb.ConsoleLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "remote@host"
    assert html =~ "Run command"
    assert html =~ "ReplConsole"
    assert html =~ "(remote@host)1&gt;"
    assert html =~ "Reset session"

    {:noreply, socket} =
      BeamdashWeb.ConsoleLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)

    {:noreply, socket} =
      BeamdashWeb.ConsoleLive.handle_async(
        {:evaluate, make_ref()},
        {:ok, {:ok, %{status: :ok, result: "old", output: ""}}},
        socket
      )

    assert socket.assigns.entries == []
    assert socket.assigns.session == nil
    assert socket.assigns.status == :disconnected
  end

  test "console view records errors and retains history when the session resets" do
    ref = make_ref()

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ConsoleLive.mount(%{}, %{}, socket)

    entry = %{
      id: ref,
      command: "error(bad).",
      language: :erlang,
      status: :running,
      result: "",
      output: ""
    }

    socket = Phoenix.Component.assign(socket, pending: ref, entries: [entry])

    {:noreply, socket} =
      BeamdashWeb.ConsoleLive.handle_async(
        {:evaluate, ref},
        {:ok, {:ok, %{status: :error, result: "bad", output: "before"}}},
        socket
      )

    assert [result] = socket.assigns.entries
    assert result.result == "bad"
    assert socket.assigns.pending == nil
    {:noreply, socket} = BeamdashWeb.ConsoleLive.handle_event("reset", %{}, socket)
    assert socket.assigns.entries == [result]
    {:noreply, socket} = BeamdashWeb.ConsoleLive.handle_event("reuse", %{"index" => "0"}, socket)
    assert socket.assigns.command == entry.command
  end

  test "completes loaded modules and exported functions for both languages" do
    Code.ensure_loaded!(Enum)
    assert Enum.any?(Console.complete(node(), :elixir, "Enu"), &(&1.insert == "Enum."))

    assert Enum.any?(
             Console.complete(node(), :elixir, "Enum.ma"),
             &(&1.label == "Enum.map/2" and &1.insert == "Enum.map(")
           )

    assert Enum.any?(Console.complete(node(), :erlang, "lis"), &(&1.insert == "lists:"))

    assert Enum.any?(
             Console.complete(node(), :erlang, "lists:ma"),
             &(&1.label == "lists:map/2" and &1.insert == "lists:map(")
           )

    assert Enum.any?(
             Console.complete(node(), :elixir, ":lists.ma"),
             &(&1.insert == ":lists.map(")
           )

    assert Enum.any?(
             Console.complete(node(), :erlang, "erlang:node"),
             &(&1.insert == "erlang:node()")
           )

    assert Console.complete(node(), :elixir, "UnknownModuleThatIsNotLoaded.foo") == []
  end

  test "Elixir notebook evaluations retain aliases and support a configurable timeout" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)
    assert {:ok, %{status: :ok}} = Console.eval(node(), session, "alias String, as: Text")

    assert {:ok, %{status: :ok, result: "3"}} =
             Console.eval(node(), session, ~s|Text.length("abc")|)

    assert {:ok, %{status: :error, result: result}} =
             Console.eval(node(), session, "Process.sleep(:infinity)", 100)

    assert result =~ "timed out"
  end
end
