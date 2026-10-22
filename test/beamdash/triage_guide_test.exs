defmodule Beamdash.TriageGuideTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias BeamdashWeb.{ProcessDetails, TriageGuide}

  defp detail(changes \\ %{}) do
    Beamdash.Test.Fixture.gc_detail()
    |> Map.merge(%{
      reductions: 1,
      links: [],
      monitors: [],
      monitored_by: [],
      current_stacktrace: [],
      trap_exit: false,
      priority: :normal,
      initial_call: {:demo_shop, :init, 1}
    })
    |> Map.merge(changes)
  end

  defp flag(choice, label),
    do: %{flagged: true, choice: choice, label: label, worth: 0.72, alternative: nil}

  defp text(step),
    do:
      Enum.map_join(step.text, fn
        {:code, c} -> c
        s -> s
      end)

  test "every investigation triage can suggest has steps" do
    for {choice, _} <- Beamdash.ProcessAdvisor.choices(), choice != "no_clear_issue" do
      steps = TriageGuide.steps(choice, detail(), :gen_server)
      assert steps != [], choice
      assert Enum.all?(steps, &(is_binary(text(&1)) and text(&1) != "")), choice
    end
  end

  test "a call waiting for a reply points at the process it called" do
    callee = spawn(fn -> :ok end)

    steps =
      TriageGuide.steps(
        "inspect_blocking",
        detail(%{current_function: {:gen, :do_call, 4}, monitors: [{:process, callee}]}),
        :gen_server
      )

    texts = Enum.map(steps, &text/1)
    assert Enum.any?(texts, &(&1 =~ "gen:do_call"))
    assert Enum.any?(texts, &(&1 =~ "waiting for another process's reply"))
    assert Enum.any?(steps, &({:open, callee} in &1.actions))
    assert Enum.any?(steps, &({:panel, "state", "State"} in &1.actions))

    assert Enum.any?(
             steps,
             &({:navigate, "/trace?mod=demo_shop", "Tracing: demo_shop"} in &1.actions)
           )
  end

  test "idle memory: Force GC, State, then how to fix it" do
    steps = TriageGuide.steps("review_idle_memory", detail(), :gen_server)
    actions = Enum.flat_map(steps, & &1.actions)
    assert {:event, "gc", "Force GC", _} = hd(actions)
    assert {:panel, "state", "State"} in actions
    assert List.last(steps) |> text() =~ "hibernate_after"
    # no State step for a process that is not a gen_server
    refute TriageGuide.steps("review_idle_memory", detail(), nil)
           |> Enum.flat_map(& &1.actions)
           |> Enum.member?({:panel, "state", "State"})
  end

  test "the flagged process's panel shows the flag and how to check it" do
    html =
      render_component(&ProcessDetails.panel/1,
        details: detail(%{current_function: {:demo_shop, :wait, 0}}),
        history: [],
        syntax: :erlang,
        kind: :gen_server,
        flag: flag("inspect_blocking", "Inspect what it waits on")
      )

    assert html =~ ~s(id="triage-guide")
    assert html =~ "⚑ Inspect what it waits on"
    assert html =~ "72% worth a look"
    assert html =~ "How to check it"
    assert html =~ "<code>demo_shop:wait/0</code> and Current stack"
    # no template whitespace around code parts
    assert html =~ "Typical waits: <code>gen:do_call</code> (a call"
    assert html =~ ~s(href="/trace?mod=demo_shop")

    refute render_component(&ProcessDetails.panel/1,
             details: detail(),
             history: [],
             syntax: :erlang
           ) =~ "triage-guide"
  end
end
