defmodule Beamdash.TermTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias BeamdashWeb.TermTree

  defp render(value, expand \\ 2) do
    rendered_to_string(
      TermTree.tree(%{value: value, syntax: :erlang, expand: expand, __changed__: nil})
    )
  end

  test "a value that fits on one line is a single leaf" do
    assert {:leaf, "{a,1}"} = TermTree.build({:a, 1}, :erlang)
  end

  test "a big tuple opens into its elements, and plain elements share a line" do
    big = {:dict, 0, 16, 16, 8, 80, 48, Enum.to_list(1..60)}

    assert {:group, "{", "}", 8, [{nil, {:leaf, leading}}, {nil, {:group, "[", "]", 60, _, _}}],
            0} = TermTree.build(big, :erlang)

    assert leading == "dict, 0, 16, 16, 8, 80, 48"
  end

  test "a big map keeps its keys and shows each value next to its key" do
    big = %{k: String.duplicate("v", 90)}

    assert {:group, "\#{", "}", 1, [{"k", {:leaf, _}}], 0} = TermTree.build(big, :erlang)
  end

  test "a long list shows its first 100 elements and counts the rest" do
    assert {:group, "[", "]", 150, [{nil, {:leaf, text}}], 50} =
             TermTree.build(Enum.to_list(1..150), :erlang)

    assert text == Enum.map_join(1..100, ", ", &Integer.to_string/1)
  end

  test "a printable charlist, an improper list and empty containers are plain text" do
    assert {:leaf, _} = TermTree.build(~c"abc", :erlang)
    assert {:leaf, _} = TermTree.build([1 | 2], :erlang)
    assert {:leaf, _} = TermTree.build([], :erlang)
    assert {:leaf, _} = TermTree.build({}, :erlang)
  end

  test "a huge nested value stops at the node budget" do
    html = render(Enum.map(1..100, fn _ -> Enum.to_list(1..100) end))

    assert length(Regex.scan(~r/class="term-leaf/, html)) <= 2_000
    assert html =~ "…"
  end

  test "the first levels render expanded and deeper ones collapsed" do
    value = {:a, Enum.map(1..30, &{:k, &1, String.duplicate("v", 5)})}
    html = render(value, 1)

    assert html =~ ~s(<details class="term-group" open>)
    assert html =~ ~s(<details class="term-group">)
  end
end
