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
      # the tree tab is the default; the details are on the other tab
      assert html =~ ~r/<button[^>]*role="tab"[^>]*aria-selected="true"[^>]*>\s*Process tree/
      assert html =~ ~r/<button[^>]*role="tab"[^>]*aria-selected="false"[^>]*>\s*Details/
      refute html =~ ~s(class="apps-details")

      assert html =~
               ~r/<g class="app-box selected"[^>]*phx-value-pid="#{kernel_sup.pid |> Beamdash.Format.pid(:erlang) |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string() |> Regex.escape()}"/

      assert html =~
               ~s(href="/?pid=#{URI.encode_www_form(Beamdash.Format.pid(kernel_sup.pid, :erlang))}")

      assert html =~ "Process info"
      assert html =~ ~s(href="/apps")
    end

    test "a process of the tree: its details and the module that runs it", %{node: node} do
      {:ok, tree} = Apps.tree(node, :kernel)
      [code_server, kernel_sup] = for n <- [:code_server, :kernel_sup], do: find(tree, n)

      assert {:ok, %{process: p, module: m}} = Apps.process(node, code_server.pid)
      assert p.registered_name == :code_server
      assert is_integer(p.reductions) and is_integer(p.memory.total)
      # the queued messages aren't copied
      assert p.mailbox.messages in [[], :not_fetched]
      assert m.module == :code_server
      assert m.application == :kernel
      assert m.exports > 0
      assert is_binary(m.file) or is_atom(m.file)

      # a supervisor: its callback module, not supervisor
      assert {:ok, %{module: %{module: :kernel, behaviours: behaviours}}} =
               Apps.process(node, kernel_sup.pid)

      assert :supervisor in behaviours

      dead = :erpc.call(node, :erlang, :spawn, [:erlang, :is_atom, [1]])
      Process.sleep(50)
      assert {:ok, nil} = Apps.process(node, dead)
    end

    test "process_module/1: the callback module, else what it runs now" do
      assert Apps.process_module(%{initial_call: {:my_server, :init, 1}}) == :my_server
      assert Apps.process_module(%{initial_call: {:supervisor, :my_sup, 1}}) == :my_sup

      assert Apps.process_module(%{
               initial_call: {:erlang, :apply, 2},
               current_function: {:my_mod, :loop, 1}
             }) == :my_mod

      assert Apps.process_module(%{initial_call: nil, current_function: nil}) == nil
    end

    test "the selected process's module source opens in a tab of the application's tabs",
         %{node: node} do
      {:ok, apps} = Apps.list(node)
      {:ok, tree} = Apps.tree(node, :kernel)
      code_server = find(tree, :code_server)

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = AppsLive.mount(%{}, %{}, socket)

      socket =
        Phoenix.Component.assign(socket,
          syntax: :erlang,
          status: :connected,
          node: node,
          apps: apps,
          app: :kernel,
          tree: tree
        )

      event = fn socket, name, params ->
        {:noreply, socket} = AppsLive.handle_event(name, params, socket)
        socket
      end

      render = fn socket ->
        socket.assigns
        |> Map.put(:socket, socket)
        |> AppsLive.render()
        |> Phoenix.LiveViewTest.rendered_to_string()
      end

      socket = event.(socket, "select", %{"pid" => Beamdash.Format.pid(code_server.pid, :erlang)})
      html = render.(socket)
      assert html =~ ~r/<button[^>]*phx-click="open_source"[^>]*phx-value-mod="code_server"/

      # only the selected process's module is taken
      assert event.(socket, "open_source", %{"mod" => "lists"}).assigns.sources == []

      socket = event.(socket, "open_source", %{"mod" => "code_server"})
      assert socket.assigns.source_tab == :code_server
      html = render.(socket)
      # a tab in the application's row, shown instead of the tree
      assert html =~
               ~r/<nav class="seg apps-tabs"[^>]*>.*phx-value-tab="code_server".*<\/nav>/s

      assert html =~ ~r/<button[^>]*aria-selected="false"[^>]*phx-value-view="tree"/
      assert html =~ ~s(class="src-panel")
      assert html =~ "-module(code_server)"
      refute html =~ ~s(class="app-chart")

      # back to the tree: the source tab stays open, the process stays selected
      socket = event.(socket, "view", %{"view" => "tree"})
      html = render.(socket)
      assert html =~ ~s(class="app-chart")
      assert html =~ ~s(phx-value-tab="code_server")
      refute html =~ ~s(class="src-panel")
      assert socket.assigns.selected == code_server.pid

      # closing the last source shows the tab it came from
      socket = event.(socket, "source_tab", %{"tab" => "code_server"})
      socket = event.(socket, "close_source", %{"mod" => "code_server"})
      assert socket.assigns.sources == [] and socket.assigns.source_tab == nil
      assert render.(socket) =~ ~s(class="app-chart")
    end

    test "the selected process shows its details, its module and links to trace or profile it",
         %{node: node} do
      {:ok, apps} = Apps.list(node)
      {:ok, tree} = Apps.tree(node, :kernel)
      code_server = find(tree, :code_server)
      {:ok, proc} = Apps.process(node, code_server.pid)

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = AppsLive.mount(%{}, %{}, socket)

      render = fn extra ->
        socket.assigns
        |> Map.merge(%{
          syntax: :erlang,
          status: :connected,
          node: node,
          apps: apps,
          app: :kernel,
          tree: tree,
          selected: code_server.pid
        })
        |> Map.merge(extra)
        |> AppsLive.render()
        |> Phoenix.LiveViewTest.rendered_to_string()
      end

      html = render.(%{proc: proc})
      assert html =~ ~s(<div class="apps-proc">)
      assert html =~ ~r/<dt>Current function<\/dt>\s*<dd class="mono">[a-z_]+:[a-z_]+\/\d+/
      assert html =~ ~r/<dt>Message queue<\/dt>/
      assert html =~ ~r/<strong class="mono">code_server<\/strong>/
      assert html =~ ~s(href="/trace?mod=code_server")
      assert html =~ ~s(href="/profile?mod=code_server")

      assert render.(%{proc: :exited}) =~ "The process has exited."
    end

    test "an application's keys, environment, start type and who needs it", %{node: node} do
      assert {:ok, info} = Apps.info(node, :kernel)
      assert info.start_type == :permanent
      assert info.mod == {:kernel, []}
      assert info.applications == []
      assert :stdlib in info.needed_by
      assert info.modules > 50
      assert :code_server in info.registered
      assert info.path =~ "kernel"
      assert is_list(info.env)

      assert {:ok, stdlib} = Apps.info(node, :stdlib)
      assert stdlib.applications == [:kernel]
      assert stdlib.mod == []

      assert {:ok, nil} = Apps.info(node, :no_such_app)
    end

    test "the tab is picked by its button, and only tree or details" do
      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = AppsLive.mount(%{}, %{}, socket)
      assert socket.assigns.view == :tree
      {:noreply, socket} = AppsLive.handle_event("view", %{"view" => "details"}, socket)
      assert socket.assigns.view == :details
      {:noreply, socket} = AppsLive.handle_event("view", %{"view" => "tree"}, socket)
      assert socket.assigns.view == :tree
    end

    test "a plugin that supports the application adds a tab with its main page", %{node: node} do
      {:ok, apps} = Apps.list(node)
      {:ok, tree} = Apps.tree(node, :kernel)

      plugin = %{
        app: :kernel_plugin,
        name: "Kernel tools",
        module: KernelPlugin,
        pages: [],
        main: %{slug: "overview", label: "Overview", module: KernelPlugin.OverviewLive},
        supports: [:kernel]
      }

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      # the bar's @conn, as the Connection hook sets it, with the plugin active
      {:cont, socket} = BeamdashWeb.Connection.on_mount(:default, %{}, %{}, socket)
      {:ok, socket} = AppsLive.mount(%{}, %{}, socket)

      socket =
        Phoenix.Component.assign(socket,
          syntax: :erlang,
          status: :connected,
          node: node,
          apps: apps,
          app: :kernel,
          tree: tree,
          conn: %{socket.assigns.conn | plugins: [plugin]}
        )

      # as LiveView renders: with @socket (here not connected)
      render = fn socket ->
        socket.assigns
        |> Map.put(:socket, socket)
        |> AppsLive.render()
        |> Phoenix.LiveViewTest.rendered_to_string()
      end

      html = render.(socket)
      assert html =~ ~r/<button[^>]*phx-value-view="plugin:kernel_plugin"[^>]*>\s*Overview/
      assert html =~ "Kernel tools"

      {:noreply, socket} =
        AppsLive.handle_event("view", %{"view" => "plugin:kernel_plugin"}, socket)

      assert socket.assigns.view == {:plugin, :kernel_plugin}
      html = render.(socket)

      assert html =~
               ~r/<button[^>]*aria-selected="true"[^>]*phx-value-view="plugin:kernel_plugin"/

      # the page itself only once connected, as on the plugin's own page
      assert html =~ "Loading Overview…"
      refute html =~ ~s(class="app-chart")

      # another application: no plugin tab, and the tree shows
      html = render.(Phoenix.Component.assign(socket, app: :stdlib, tree: nil))
      refute html =~ "plugin:kernel_plugin"
      refute html =~ "Loading Overview…"

      # a plugin that isn't active (or doesn't support it) can't be picked
      {:noreply, socket} = AppsLive.handle_event("view", %{"view" => "plugin:other"}, socket)
      assert socket.assigns.view == {:plugin, :kernel_plugin}
    end

    test "the page shows the selected application's details", %{node: node} do
      {:ok, apps} = Apps.list(node)
      {:ok, tree} = Apps.tree(node, :kernel)
      {:ok, info} = Apps.info(node, :kernel)

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = AppsLive.mount(%{}, %{}, socket)

      html =
        socket.assigns
        |> Map.merge(%{
          syntax: :erlang,
          status: :connected,
          node: node,
          apps: apps,
          app: :kernel,
          tree: tree,
          info: %{info | env: [{:secret_key, ~c"abc"}]},
          view: :details
        })
        |> AppsLive.render()
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ ~s(<dl class="apps-details">)
      refute html =~ ~s(class="app-chart")
      assert html =~ ~r/<dt>Started<\/dt>\s*<dd>permanent<\/dd>/
      assert html =~ ~r/<dt>Callback<\/dt>\s*<dd class="mono">kernel \[\]<\/dd>/
      assert html =~ ~r/<dt>Depends on<\/dt>\s*<dd>\s*<span class="muted">none<\/span>/
      # needed by stdlib, a library application: plain text, not a link
      assert html =~ ~r/<dt>Needed by<\/dt>\s*<dd>.*stdlib/s
      refute html =~ ~s(phx-value-app="stdlib")
      # the environment, folded
      assert html =~
               ~r/<details id="apps-env" class="apps-env" phx-mounted="[^"]*ignore_attrs[^"]*open/

      assert html =~ "secret_key"
      assert html =~ "&quot;abc&quot;"
    end
  end

  defp flatten(node), do: [node | Enum.flat_map(node.children, &flatten/1)]
  defp find(tree, name), do: tree.root |> flatten() |> Enum.find(&(&1.name == name))
end
