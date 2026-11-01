defmodule Beamdash.ConsoleTest do
  use ExUnit.Case, async: false
  alias Beamdash.Console
  alias Beamdash.Test.Fixture

  setup context do
    if context[:mock_kino] do
      :ok = Application.stop(:kino)
      on_exit(fn -> {:ok, _} = Application.ensure_all_started(:kino) end)
    end

    :ok
  end

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

  test "local and remote Elixir sessions retain independent bindings" do
    elixir_ebin =
      :elixir |> :code.lib_dir() |> List.to_string() |> Path.join("ebin") |> String.to_charlist()

    {peer, remote} = Fixture.start_peer([~c"-pa", elixir_ebin])
    on_exit(fn -> Fixture.stop_peer(peer) end)
    true = Node.set_cookie(remote, :beamdash_test_cookie)
    assert {:ok, _} = :erpc.call(remote, :application, :ensure_all_started, [:elixir])
    assert {:ok, local_session} = Console.start(node(), self(), :elixir)
    assert {:ok, remote_session} = Console.start(remote, self(), :elixir)

    on_exit(fn ->
      Console.stop(local_session)
      Console.stop(remote_session)
    end)

    assert {:ok, %{status: :ok}} = Console.eval(node(), local_session, "value = :local")
    assert {:ok, %{status: :ok}} = Console.eval(remote, remote_session, "value = :remote")
    assert {:ok, %{result: ":local"}} = Console.eval(node(), local_session, "value")
    assert {:ok, %{result: ":remote"}} = Console.eval(remote, remote_session, "value")
    assert {:ok, %{result: remote_node}} = Console.eval(remote, remote_session, "node()")
    assert remote_node =~ Atom.to_string(remote)
  end

  test "Elixir evaluation preserves bindings" do
    assert {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)
    assert {:ok, %{status: :ok}} = Console.eval(node(), session, "x = 7")

    assert {:ok, %{result: "14", output: "hello\n"}} =
             Console.eval(node(), session, "IO.puts(\"hello\"); x * 2")
  end

  test "Kino text inputs keep their values in the evaluator session" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    code =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "field-1", attrs: %{type: :text, label: "Name", default: "Ada"}}|

    assert {:ok, %{status: :ok, widget: %{id: "field-1", value: "Ada"}}} =
             Console.eval(node(), session, code)

    assert {:ok, :ok} = Console.set_input(node(), session, "field-1", "Grace")

    assert {:ok, %{status: :ok, result: ~S|{:ok, "Grace"}|}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_get_input_value, "field-1", self()})|
             )

    assert {:ok, {:error, :not_found}} = Console.set_input(node(), session, "unknown", "value")
  end

  @tag :mock_kino
  test "Kino checkbox and button changes reach subscribers and are released" do
    Process.register(self(), Kino.SubscriptionManager)
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    checkbox =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "check", ref: "check-ref", destination: {Kino.SubscriptionManager, node()}, attrs: %{type: :checkbox, label: "Check", default: false}}|

    assert {:ok, %{widget: %{type: :checkbox, value: false}}} =
             Console.eval(node(), session, checkbox)

    assert {:ok, :ok} = Console.set_input(node(), session, "check", "true")
    assert_receive {:event, "check-ref", %{type: :change, value: true, origin: "beamdash"}}

    assert {:ok, %{result: "{:ok, true}"}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_get_input_value, "check", self()})|
             )

    assert {:ok, :ok} = Console.release_input(node(), session, "check")
    assert_receive {:clear_topic, "check-ref"}
    assert {:ok, {:error, :not_found}} = Console.set_input(node(), session, "check", "false")

    button =
      ~S|%{__struct__: :"Elixir.Kino.Control", ref: "button-ref", destination: {Kino.SubscriptionManager, node()}, attrs: %{type: :button, label: "Run"}}|

    assert {:ok, %{widget: %{type: :button, id: "button-ref"}}} =
             Console.eval(node(), session, button)

    assert {:ok, :ok} = Console.set_input(node(), session, "button-ref", "click")
    assert_receive {:event, "button-ref", %{type: :click, origin: "beamdash"}}
  end

  test "renders Kino text output and forwards output from background processes" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{status: :ok, output: "rendered"}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :plain_text, text: "rendered"}}); :ok|
             )

    assert {:ok, %{status: :ok}} =
             Console.eval(
               node(),
               session,
               ~S|spawn(fn -> Process.sleep(100); IO.write("listener") end); :ok|
             )

    assert_receive {:beamdash_console_output, ^session, "listener"}, 2_000
  end

  test "Kino numeric inputs return numbers and enforce bounds" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    code =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "n", attrs: %{type: :number, label: "Count", default: 2, min: 0, max: 10}}|

    assert {:ok, %{widget: %{type: :number, value: 2}}} = Console.eval(node(), session, code)
    assert {:ok, :ok} = Console.set_input(node(), session, "n", "4.5")

    assert {:ok, %{result: "{:ok, 4.5}"}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_get_input_value, "n", self()})|
             )

    assert {:ok, {:error, :invalid_value}} = Console.set_input(node(), session, "n", "11")
  end

  test "Kino select keeps option values on the target and returns the selected term" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    code =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "choice", attrs: %{type: :select, label: "Choice", default: {:one, 1}, options: [{{:one, 1}, "First"}, {{:two, 2}, "Second"}]}}|

    assert {:ok,
            %{
              result: "",
              widget: %{type: :select, value: 0, options: [{0, "First"}, {1, "Second"}]}
            }} =
             Console.eval(node(), session, code)

    assert {:ok, :ok} = Console.set_input(node(), session, "choice", "1")

    assert {:ok, %{result: "{:ok, {:two, 2}}"}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_get_input_value, "choice", self()})|
             )

    assert {:ok, {:error, :invalid_value}} = Console.set_input(node(), session, "choice", "8")
  end

  test "Kino password and color inputs preserve types without printing password defaults" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    password =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "pw", attrs: %{type: :password, label: "Password", default: "secret"}}|

    assert {:ok, %{result: "", widget: %{type: :password}}} =
             Console.eval(node(), session, password)

    assert {:ok, :ok} = Console.set_input(node(), session, "pw", "new-secret")

    assert {:ok, %{result: ~S|{:ok, "new-secret"}|}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_get_input_value, "pw", self()})|
             )

    color =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "color", attrs: %{type: :color, label: "Color", default: "#6583FF"}}|

    assert {:ok, %{widget: %{type: :color}}} = Console.eval(node(), session, color)
    assert {:ok, :ok} = Console.set_input(node(), session, "color", "#123abc")

    assert {:ok, {:error, :invalid_value}} =
             Console.set_input(node(), session, "color", "invalid")
  end

  test "Kino URL and date inputs preserve typed values and date bounds" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    url =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "url", attrs: %{type: :url, label: "URL", default: nil}}|

    assert {:ok, %{widget: %{type: :url, value: nil}}} = Console.eval(node(), session, url)
    assert {:ok, :ok} = Console.set_input(node(), session, "url", "https://example.com")

    assert {:ok, {:error, :invalid_value}} =
             Console.set_input(node(), session, "url", "not a url")

    assert {:ok, :ok} = Console.set_input(node(), session, "url", "")

    assert {:ok, %{result: "{:ok, nil}"}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_get_input_value, "url", self()})|
             )

    date =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "date", attrs: %{type: :date, label: "Date", default: ~D[2024-02-01], min: ~D[2024-01-01], max: ~D[2024-12-31]}}|

    assert {:ok, %{widget: %{type: :date, value: "2024-02-01"}}} =
             Console.eval(node(), session, date)

    assert {:ok, :ok} = Console.set_input(node(), session, "date", "2024-06-12")

    assert {:ok, %{result: "{:ok, ~D[2024-06-12]}"}} =
             Console.eval(
               node(),
               session,
               ~S|:io.request(Process.group_leader(), {:livebook_get_input_value, "date", self()})|
             )

    assert {:ok, {:error, :invalid_value}} =
             Console.set_input(node(), session, "date", "2025-01-01")

    assert {:ok, {:error, :invalid_value}} =
             Console.set_input(node(), session, "date", "2024-02-30")
  end

  test "direct Kino text and markdown are bounded rich outputs" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{widget: %{type: :markdown, text: "**bold**"}}} =
             Console.eval(
               node(),
               session,
               ~S|%{__struct__: :"Elixir.Kino.Markdown", text: "**bold**"}|
             )

    assert {:ok, %{widget: %{type: :plain_text, text: "hello"}}} =
             Console.eval(node(), session, ~S|%{__struct__: :"Elixir.Kino.Text", text: "hello"}|)

    assert {:ok, response} =
             Console.eval(
               node(),
               session,
               ~S|%{__struct__: :"Elixir.Kino.Markdown", text: :binary.copy("x", 16001)}|
             )

    refute Map.has_key?(response, :widget)
  end

  test "VegaLite specifications are returned as bounded charts" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    code =
      ~S|%{__struct__: :"Elixir.VegaLite", spec: %{"mark" => "bar", "data" => %{"values" => [%{"x" => 3}]}}}|

    assert {:ok, %{widget: %{type: :chart, spec: %{"mark" => "bar"}}}} =
             Console.eval(node(), session, code)

    too_large =
      ~S|%{__struct__: :"Elixir.VegaLite", spec: %{"data" => :binary.copy("x", 1_048_577)}}|

    assert {:ok, response} = Console.eval(node(), session, too_large)
    refute Map.has_key?(response, :widget)
  end

  test "reports a missing Kino module with an actionable explanation" do
    assert :code.which(Kino.AbsentForTest) == :non_existing
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{status: :error, result: message}} =
             Console.eval(
               node(),
               session,
               ~S|Kino.AbsentForTest.text("Name", default: "Ada")|
             )

    assert message =~ "Kino.AbsentForTest.text/2"
    assert message =~ "not available on the connected node"
    assert message =~ "Kino"
    assert {:ok, %{status: :ok, result: "2"}} = Console.eval(node(), session, "1 + 1")
  end

  test "Kino raster images are bounded and use an allowlisted MIME type" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)
    png = ~S|%{__struct__: :"Elixir.Kino.Image", content: <<1, 2, 3>>, mime_type: "image/png"}|

    assert {:ok, %{result: "", widget: %{type: :image, mime: "image/png", data: "AQID"}}} =
             Console.eval(node(), session, png)

    svg = ~S|%{__struct__: :"Elixir.Kino.Image", content: "<svg/>", mime_type: "image/svg+xml"}|
    assert {:ok, result} = Console.eval(node(), session, svg)
    refute Map.has_key?(result, :widget)

    large =
      ~S|%{__struct__: :"Elixir.Kino.Image", content: :binary.copy(<<0>>, 1_048_577), mime_type: "image/png"}|

    assert {:ok, result} = Console.eval(node(), session, large)
    refute Map.has_key?(result, :widget)
  end

  test "shared nested frames retain controls until their final parent is released" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    update = fn parent ->
      ~s|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :frame_update, ref: "#{parent}", update: {:replace, [%{type: :frame, ref: "child", outputs: [%{type: :input, id: "shared-child", attrs: %{type: :text, label: "Name", default: "Ada"}}]}]}}})|
    end

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, update.("first"))
    assert {:ok, %{status: :ok}} = Console.eval(node(), session, update.("second"))
    assert {:ok, :ok} = Console.release_frame(node(), session, "first")
    assert {:ok, :ok} = Console.set_input(node(), session, "shared-child", "Grace")
    assert {:ok, :ok} = Console.release_frame(node(), session, "second")

    assert {:ok, {:error, :not_found}} =
             Console.set_input(node(), session, "shared-child", "orphan")
  end

  test "nested layouts in frames retain and release their controls" do
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    code =
      ~S|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :frame_update, ref: "outer", update: {:replace, [%{type: :grid, columns: 1, outputs: [%{type: :tabs, labels: ["A"], outputs: [%{type: :input, id: "nested-layout", attrs: %{type: :text, label: "Name", default: "Ada"}}]}]}]}}})|

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, code)

    assert_receive {:beamdash_kino_frame, ^session, "outer", _,
                    [
                      %{
                        type: :layout,
                        items: [
                          %{
                            type: :layout,
                            items: [%{type: :interactive, widget: %{id: "nested-layout"}}]
                          }
                        ]
                      }
                    ]}

    assert {:ok, :ok} = Console.set_input(node(), session, "nested-layout", "Grace")
    assert {:ok, :ok} = Console.release_frame(node(), session, "outer")

    assert {:ok, {:error, :not_found}} =
             Console.set_input(node(), session, "nested-layout", "lost")
  end

  @tag :mock_kino
  test "Kino text frame updates are forwarded to the notebook owner" do
    Process.register(self(), Kino.SubscriptionManager)
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    frame =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :get_items} -> GenServer.reply(from, [])
        end
      end)

    Process.register(frame, :beamdash_frame_test)

    code =
      ~S|%{__struct__: :"Elixir.Kino.Frame", ref: "frame-id", pid: Process.whereis(:beamdash_frame_test)}|

    assert {:ok, %{widget: %{type: :frame, id: "frame-id", items: []}}} =
             Console.eval(node(), session, code)

    update =
      ~S|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :frame_update, ref: "frame-id", update: {:replace, [%{type: :plain_text, text: "hello"}]}}})|

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, update)

    assert_receive {:beamdash_kino_frame, ^session, "frame-id", _,
                    [%{type: :text, text: "hello"}]}

    image =
      ~S|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :frame_update, ref: "frame-id", update: {:append, [%{type: :image, mime_type: "image/png", content: <<1, 2, 3>>}]}}})|

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, image)

    assert_receive {:beamdash_kino_frame, ^session, "frame-id", _,
                    [
                      %{type: :text, text: "hello"},
                      %{type: :image, mime: "image/png", data: "AQID"}
                    ]}

    markdown =
      ~S|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :frame_update, ref: "frame-id", update: {:append, [%{type: :markdown, text: "**bold**"}]}}})|

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, markdown)

    assert_receive {:beamdash_kino_frame, ^session, "frame-id", _,
                    [
                      %{type: :text, text: "hello"},
                      %{type: :image},
                      %{type: :markdown, text: "**bold**"}
                    ]}

    nested =
      ~S|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :frame_update, ref: "frame-id", update: {:replace, [%{type: :input, id: "nested", ref: "nested-ref", destination: {Kino.SubscriptionManager, node()}, attrs: %{type: :text, label: "Name", default: "Ada"}}]}}})|

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, nested)

    assert_receive {:beamdash_kino_frame, ^session, "frame-id", _,
                    [%{type: :interactive, widget: %{id: "nested", value: "Ada"}}]}

    assert {:ok, :ok} = Console.set_input(node(), session, "nested", "Grace")
    assert_receive {:event, "nested-ref", %{type: :change, value: "Grace"}}

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, markdown)

    assert_receive {:beamdash_kino_frame, ^session, "frame-id", _,
                    [
                      %{type: :interactive, widget: %{id: "nested", value: "Grace"}},
                      %{type: :markdown, text: "**bold**"}
                    ]}

    clear =
      ~S|:io.request(Process.group_leader(), {:livebook_put_output, %{type: :frame_update, ref: "frame-id", update: {:replace, []}}})|

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, clear)
    assert_receive {:clear_topic, "nested-ref"}
    assert {:ok, {:error, :not_found}} = Console.set_input(node(), session, "nested", "stale")

    assert {:ok, %{status: :ok}} = Console.eval(node(), session, nested)

    direct =
      ~S|%{__struct__: :"Elixir.Kino.Input", id: "nested", ref: "nested-ref", destination: {Kino.SubscriptionManager, node()}, attrs: %{type: :text, label: "Name", default: "Ada"}}|

    assert {:ok, %{widget: %{id: "nested"}}} = Console.eval(node(), session, direct)
    assert {:ok, %{status: :ok}} = Console.eval(node(), session, clear)
    refute_receive {:clear_topic, "nested-ref"}, 100
    assert {:ok, :ok} = Console.set_input(node(), session, "nested", "shared")
    assert {:ok, :ok} = Console.release_input(node(), session, "nested")
    assert_receive {:clear_topic, "nested-ref"}
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
