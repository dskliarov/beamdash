defmodule BeamdashWeb.AppChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias BeamdashWeb.AppChart

  defp child_pid, do: :erlang.list_to_pid(~c"<0.200.0>")

  defp outline(root, selected \\ nil) do
    rendered_to_string(
      AppChart.outline(%{
        id: "app-outline",
        root: root,
        selected: selected,
        syntax: :erlang,
        __changed__: nil
      })
    )
  end

  defp child, do: %{pid: child_pid(), name: :child, label: nil, children: [], also: []}

  test "the outline nests each process under its parent and makes it selectable" do
    root = %{pid: self(), name: :root, label: nil, children: [child()], also: []}
    html = outline(root)

    assert length(Regex.scan(~r/<details/, html)) == 1
    assert html =~ ~s(phx-value-pid="&lt;0.200.0&gt;")
    assert html =~ "child"
  end

  test "the selected process is marked" do
    root = %{pid: self(), name: :root, label: nil, children: [child()], also: []}

    assert outline(root, child_pid()) =~ ~s(class="app-outline-item mono selected")
  end

  test "a process that is not a pid is shown without a select button" do
    root = %{pid: :ghost, name: nil, label: nil, children: [], also: []}
    html = outline(root)

    assert html =~ ~s(app-outline-item mono static)
    refute html =~ "phx-click=\"select\""
  end

  test "the outline has Expand all and Collapse all" do
    html = outline(%{pid: self(), name: :root, label: nil, children: [], also: []})

    assert html =~ "Expand all"
    assert html =~ "Collapse all"
  end
end
