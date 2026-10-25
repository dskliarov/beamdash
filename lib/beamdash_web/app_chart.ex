defmodule BeamdashWeb.AppChart do
  @moduledoc """
  The application process chart as Observer draws it (observer_app_wx):
  boxes left to right, one column per tree depth as wide as its widest
  box, a parent centred between its first and last child, right-angled
  connectors, secondary links in the highlight colour. The layout is a
  port of Observer's calc_tree_size/4, with its spacing.
  """
  use Phoenix.Component

  alias Beamdash.Format

  # Observer's spacing (observer_app_wx.erl)
  # text to box edge, both ways
  @bx_e 10
  @by_e 10
  # between boxes
  @bb_x 16
  @bb_y 12

  # 12px monospace: 0.6 em per character
  @char_w 7.2
  @text_h 15

  attr :root, :map,
    required: true,
    doc: "Beamdash.Apps tree node; a node with `static: true`, or a port, is not clickable"

  attr :selected, :any, default: nil
  attr :syntax, :atom, required: true
  attr :label, :string, default: "Application process tree"
  attr :class, :string, default: nil

  def chart(assigns) do
    assigns = assign(assigns, layout: layout(assigns.root, &text(&1, assigns.syntax)))

    ~H"""
    <div class={["app-chart-scroll", @class]}>
      <svg
        class="app-chart"
        width={@layout.width}
        height={@layout.height}
        viewBox={"0 0 #{@layout.width} #{@layout.height}"}
        role="tree"
        aria-label={@label}
      >
        <polyline :for={l <- @layout.xlinks} points={l} class="app-xlink" />
        <polyline :for={l <- @layout.lines} points={l} class="app-line" />
        <g
          :for={b <- @layout.boxes}
          class={["app-box", b.pid == @selected && "selected", b.static && "static"]}
          phx-click={!b.static && "select"}
          phx-value-pid={!b.static && Format.pid(b.pid, :erlang)}
          role="treeitem"
          aria-selected={to_string(b.pid == @selected)}
          tabindex={!b.static && "0"}
          phx-keydown={!b.static && "select"}
          phx-key={!b.static && "Enter"}
        >
          <title>{b.title}</title>
          <rect x={b.x} y={b.y} width={b.w} height={b.h} rx="8" ry="8" />
          <text
            x={b.x + b.pad}
            y={b.y + div(b.h, 2)}
            dominant-baseline="central"
            textLength={b.w - 2 * b.pad}
            lengthAdjust="spacingAndGlyphs"
          >
            {b.text}
          </text>
        </g>
      </svg>
    </div>
    """
  end

  # As Observer: the registered name, else the pid (a proc_lib label too)
  defp text(%{name: name}, syntax) when not is_nil(name), do: Format.name(name, syntax)
  defp text(%{label: label}, _syntax) when not is_nil(label), do: label
  defp text(%{pid: pid}, syntax) when is_pid(pid), do: Format.pid(pid, syntax)
  # a port, or a name on another node
  defp text(%{pid: other}, syntax), do: Format.term(other, syntax, 60)

  @doc """
  `%{boxes: [%{pid, x, y, w, h, text, title}], lines: [points], xlinks:
  [points], width, height}` for a tree of `%{pid, children, also}`.
  """
  def layout(root, text_fun) do
    tree = boxes(root, text_fun)
    cols = col_start(tree, [0])
    {placed, {w, hs}} = size(tree, cols, @bb_x, [@bb_y])
    flat = flatten(placed)
    by_pid = Map.new(flat, &{&1.pid, &1})

    %{
      boxes: flat,
      lines: connectors(placed),
      xlinks: xlinks(root, by_pid),
      width: w,
      height: Enum.max(hs)
    }
  end

  defp boxes(node, text_fun) do
    text = text_fun.(node)

    box = %{
      pid: node.pid,
      text: text,
      title:
        "#{text} #{if is_pid(node.pid) and (node.name || node.label), do: Format.pid(node.pid, :erlang)}",
      static: Map.get(node, :static, false) or not is_pid(node.pid),
      w: round(String.length(text) * @char_w) + @bx_e,
      pad: div(@bx_e, 2),
      h: @text_h + @by_e
    }

    {box, Enum.map(node.children, &boxes(&1, text_fun))}
  end

  # calc_col_start/2: the width of each depth's column
  defp col_start({%{w: w}, children}, [max | acc0]) do
    acc = if acc0 == [], do: [0], else: acc0
    depth = Enum.reduce(children, acc, &col_start/2)
    [max(w, max) | depth]
  end

  # calc_tree_size/4; hs is, per depth, the next free y
  defp size({box, []}, _cols, x, [y | ys]),
    do: {{Map.merge(box, %{x: x, y: y}), []}, {x + box.w + @bb_x, [y + box.h + @bb_y | ys]}}

  defp size({box, children}, [col | cols], x, [h0 | hs0]) do
    hs1 = row_start(children, h0, hs0)
    start_x = x + col + @bb_x
    {placed, {w, hs}} = sizes(children, cols, start_x, start_x, hs1, [])
    y = middle(placed, h0)
    h = y + box.h + @bb_y
    {{Map.merge(box, %{x: x, y: y}), placed}, {w, [h | hs]}}
  end

  defp sizes([child | rest], cols, x0, w0, hs0, acc) do
    {tree, {w, hs}} = size(child, cols, x0, hs0)
    sizes(rest, cols, x0, max(w, w0), hs, [tree | acc])
  end

  defp sizes([], _cols, _x0, w, hs, acc), do: {Enum.reverse(acc), {w, hs}}

  # calc_row_start/3: children start so their parent can sit in their middle
  defp row_start([{%{h: h}, _} | _] = children, start, hs0) do
    n = length(children)
    wanted = div(h * n + @bb_y * (n - 1), 2) - div(h, 2)

    case hs0 do
      [] -> [max(@bb_y, start - wanted)]
      [next | hs] -> [max(next, start - wanted) | hs]
    end
  end

  defp middle([], y), do: y
  defp middle([{%{y: y}, _}], _), do: y
  defp middle([{%{y: y0}, _} | rest], _), do: div(y0 + elem(List.last(rest), 0).y, 2)

  defp flatten({box, children}), do: [box | Enum.flat_map(children, &flatten/1)]

  # draw_tree/3 and draw_link/3: from the parent's right edge to a spine
  # half way to the children, then across to each child.
  defp connectors({_box, []}), do: []

  defp connectors({box, [{first, _} | _] = children}) do
    cy = box.y + div(box.h, 2)
    cx = first.x - div(@bb_x, 2)

    to_children =
      for {c, _} <- children do
        y = c.y + div(c.h, 2)
        "#{cx},#{cy} #{cx},#{y} #{c.x},#{y}"
      end

    ["#{box.x + box.w},#{cy} #{cx},#{cy}" | to_children] ++
      Enum.flat_map(children, &connectors/1)
  end

  # draw_xlink/6: secondary links between boxes
  defp xlinks(root, by_pid) do
    pairs =
      for node <- nodes(root), other <- node.also, node.pid < other, do: {node.pid, other}

    for {a, b} <- pairs, from = by_pid[a], to = by_pid[b], do: xlink(from, to)
  end

  defp nodes(node), do: [node | Enum.flat_map(node.children, &nodes/1)]

  defp xlink(%{x: x, y: y0, h: h}, %{x: x, y: y1}), do: xlink_line(x, y0, x, y1, h)

  defp xlink(%{x: x0, w: w} = a, %{x: x1} = b) when x0 < x1,
    do: xlink_line(x0 + w, a.y, x1, b.y, a.h)

  defp xlink(a, %{w: w} = b), do: xlink_line(b.x + w, b.y, a.x, a.y, a.h)

  defp xlink_line(x0, y00, x1, y11, bh) do
    {y0, y1} = if y00 < y11, do: {y00 + bh - 6, y11 + 6}, else: {y00 + 6, y11 + bh - 6}
    "#{x0},#{y0} #{x0 + 5},#{y0} #{x1 - 5},#{y1} #{x1},#{y1}"
  end
end
