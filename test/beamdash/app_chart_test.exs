defmodule BeamdashWeb.AppChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias BeamdashWeb.AppChart

  defp child_pid, do: :erlang.list_to_pid(~c"<0.200.0>")

  defp outline(root, selected \\ nil, metric \\ :structure) do
    rendered_to_string(
      AppChart.outline(%{
        id: "app-outline",
        root: root,
        selected: selected,
        syntax: :erlang,
        metric: metric,
        __changed__: nil
      })
    )
  end

  defp chart(root, metric) do
    rendered_to_string(
      AppChart.chart(%{
        root: root,
        selected: nil,
        syntax: :erlang,
        metric: metric,
        label: "tree",
        class: nil,
        __changed__: nil
      })
    )
  end

  defp child, do: %{pid: child_pid(), name: :child, label: nil, children: [], also: []}

  defp proc(name, reductions, mailbox, children \\ []) do
    %{
      pid: spawn(fn -> :ok end),
      name: name,
      label: nil,
      also: [],
      reductions: reductions,
      mailbox: mailbox,
      children: children
    }
  end

  defp position(html, text), do: elem(:binary.match(html, text), 0)

  # quiet has 500 reductions; busy_branch has none itself, but its child has 900
  defp loads do
    %{
      pid: self(),
      name: :root,
      label: nil,
      also: [],
      reductions: 0,
      mailbox: 0,
      children: [
        proc(:quiet, 500, 0),
        proc(:busy_branch, 0, 0, [proc(:deep, 900, 3)])
      ]
    }
  end

  test "structure keeps the tree's order" do
    html = outline(loads())
    assert position(html, "quiet") < position(html, "busy_branch")
  end

  test "reductions put the branch with the most under it first, its total counted" do
    html = outline(loads(), nil, :reductions)
    assert position(html, "busy_branch") < position(html, "quiet")
    assert html =~ "quiet 500"
    assert html =~ "deep 900"
  end

  test "mailbox shows the queued messages in each box" do
    html = chart(loads(), :mailbox)
    assert html =~ "deep 3"
    assert html =~ "quiet 0"
  end

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
