defmodule Beamdash.AppsTest do
  # The Applications tab: Observer's application list and process trees.
  use ExUnit.Case, async: false

  alias Beamdash.{Apps, Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.AppsLive

  test "links become a tree; a second parent and secondary links become 'also' links" do
    [m, sup, a, b, c] = for _ <- 1..5, do: spawn(fn -> :ok end)

    tree =
      Apps.build(%{
        root: m,
        procs: [
          %{pid: m, name: :undefined, label: :undefined},
          %{pid: sup, name: :my_sup, label: :undefined},
          %{pid: a, name: :undefined, label: "worker 1"},
          %{pid: b, name: :undefined, label: :undefined},
          %{pid: c, name: :undefined, label: :undefined}
        ],
        links: [{m, sup}, {sup, a}, {sup, b}, {a, c}, {b, c}],
        extra: [{b, a}]
      })

    assert tree.count == 5
    assert %{pid: ^m, children: [%{pid: ^sup, name: :my_sup, children: [na, nb]}]} = tree.root
    assert %{pid: ^a, label: "worker 1", children: [%{pid: ^c}], also: [^b]} = na
    # c is drawn under a only
    assert %{pid: ^b, children: [], also: [^a]} = nb
  end

  test "the chart is laid out as Observer lays it out" do
    [m, sup, a, b] = for _ <- 1..4, do: spawn(fn -> :ok end)
    leaf = fn pid, name -> %{pid: pid, name: name, label: nil, children: [], also: []} end

    root = %{
      pid: m,
      name: nil,
      label: nil,
      also: [],
      children: [
        %{
          pid: sup,
          name: :my_sup,
          label: nil,
          also: [],
          children: [%{leaf.(a, :a) | also: [b]}, %{leaf.(b, :a_much_longer_name) | also: [a]}]
        }
      ]
    }

    l = BeamdashWeb.AppChart.layout(root, &((&1.name && Atom.to_string(&1.name)) || "<0.1.0>"))
    by = Map.new(l.boxes, &{&1.pid, &1})
    # one column per depth, starting 16 px apart, as wide as its widest box
    assert by[m].x == 16
    assert by[sup].x == by[m].x + by[m].w + 16
    assert by[a].x == by[b].x
    assert by[a].x == by[sup].x + by[sup].w + 16
    # children stacked 12 px apart; their parent sits in their middle
    assert by[b].y == by[a].y + by[a].h + 12
    assert by[sup].y == div(by[a].y + by[b].y, 2)
    assert by[m].y == by[sup].y
    assert by[a].h == 25 and by[a].w == round(String.length("a") * 7.2) + 10
    # parent -> spine -> each child, and one secondary link
    assert length(l.lines) == 2 + 2 + 1
    assert [xlink] = l.xlinks
    assert xlink =~ "#{by[a].x}"
    assert l.width == by[b].x + by[b].w + 16
    assert l.height == by[b].y + by[b].h + 12
  end

  describe "on a node" do
    setup do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      target =
        start_supervised!({Target, name: :"apps_target_#{System.unique_integer([:positive])}"})

      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      %{node: node}
    end

    test "lists the running applications and walks kernel's tree", %{node: node} do
      assert {:ok, apps} = Apps.list(node)
      kernel = Enum.find(apps, &(&1.name == :kernel))
      assert is_pid(kernel.master) and is_binary(kernel.vsn) and kernel.description != ""

      assert {:ok, %{root: root, count: count}} = Apps.tree(node, :kernel)
      assert root.pid == kernel.master
      assert count > 5
      names = flatten(root) |> Enum.map(& &1.name)
      assert :kernel_sup in names
      assert :code_server in names
      # the runtime's own processes are left out, as in Observer
      refute :application_controller in names
      refute :init in names

      assert {:ok, nil} = Apps.tree(node, :no_such_app)
    end

    test "the page lists applications and draws the tree", %{node: node} do
      {:ok, apps} = Apps.list(node)
      {:ok, tree} = Apps.tree(node, :kernel)

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = AppsLive.mount(%{}, %{}, socket)
      kernel_sup = flatten(tree.root) |> Enum.find(&(&1.name == :kernel_sup))

      html =
        socket.assigns
        |> Map.merge(%{
          syntax: :erlang,
          status: :connected,
          node: node,
          apps: apps,
          app: :kernel,
          tree: tree,
          selected: kernel_sup.pid
        })
        |> AppsLive.render()
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ ~s(phx-value-app="kernel")
      assert html =~ "kernel_sup"
      assert html =~ "code_server"
      assert html =~ ~r/[\d,]+ processes · as Observer/
      # drawn as Observer's chart: boxes with the names, the selected one highlighted
      assert html =~ ~s(class="app-chart")

      assert html =~
               ~r/<g class="app-box selected"[^>]*phx-value-pid="#{kernel_sup.pid |> Beamdash.Format.pid(:erlang) |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string() |> Regex.escape()}"/

      assert html =~
               ~s(href="/?pid=#{URI.encode_www_form(Beamdash.Format.pid(kernel_sup.pid, :erlang))}")

      assert html =~ "Process info"
      assert html =~ ~s(href="/apps")
    end
  end

  defp flatten(node), do: [node | Enum.flat_map(node.children, &flatten/1)]
end
