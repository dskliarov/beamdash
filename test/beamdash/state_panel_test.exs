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

  test "the state is shown as text by default" do
    html = html(panel(@big))

    assert html =~ "state-pre"
    refute html =~ "state-tree"
  end

  test "the Tree switch shows the state as nested blocks" do
    {:noreply, socket} = StatePanel.handle_event("set_view", %{"view" => "tree"}, panel(@big))
    html = html(socket)

    assert html =~ "state-tree"
    assert html =~ ~s(class="term-group")
    refute html =~ "state-pre"
  end

  test "the Text switch goes back to the text view" do
    {:noreply, tree} = StatePanel.handle_event("set_view", %{"view" => "tree"}, panel(@big))
    {:noreply, socket} = StatePanel.handle_event("set_view", %{"view" => "text"}, tree)

    assert html(socket) =~ "state-pre"
  end
end
