defmodule BeamdashWeb.StatePanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias BeamdashWeb.StatePanel

  defp panel(state) do
    {:ok, socket} = StatePanel.mount(%Phoenix.LiveView.Socket{})

    %{
      socket
      | assigns:
          Map.merge(socket.assigns, %{
            key: "1",
            label: "worker",
            active: true,
            pid: self(),
            proc_kind: :gen_server,
            syntax: :erlang,
            myself: %Phoenix.LiveComponent.CID{cid: 1},
            loading: false,
            result: {:ok, %{state: state, module: nil, at: DateTime.utc_now()}}
          })
    }
  end

  defp html(socket), do: rendered_to_string(StatePanel.render(socket.assigns))

  @big Enum.map(1..30, &{:k, &1, String.duplicate("v", 5)})

  test "the state is shown pretty printed by default" do
    html = html(panel(@big))

    assert html =~ "term-text"
    refute html =~ "term-tree"
  end

  test "the Tree switch shows the state as nested blocks" do
    {:noreply, socket} = StatePanel.handle_event("set_view", %{"view" => "tree"}, panel(@big))
    html = html(socket)

    assert html =~ "term-tree"
    assert html =~ ~s(class="term-group")
    refute html =~ "term-text"
  end

  test "the Raw switch shows the state on one line" do
    {:noreply, socket} = StatePanel.handle_event("set_view", %{"view" => "raw"}, panel(@big))

    assert html(socket) =~ "term-text"
    refute html(socket) =~ "term-tree"
    refute html(socket) =~ "tok-"
  end

  test "Expand all and Collapse all appear only in the tree view" do
    {:noreply, tree} = StatePanel.handle_event("set_view", %{"view" => "tree"}, panel(@big))

    assert html(tree) =~ "Expand all"
    assert html(tree) =~ "Collapse all"
    refute html(panel(@big)) =~ "Expand all"
  end

  test "the Pretty switch goes back to the coloured text view" do
    {:noreply, tree} = StatePanel.handle_event("set_view", %{"view" => "tree"}, panel(@big))
    {:noreply, socket} = StatePanel.handle_event("set_view", %{"view" => "pretty"}, tree)

    assert html(socket) =~ "term-text"
    assert html(socket) =~ "tok-atom"
  end
end
