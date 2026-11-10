defmodule Beamdash.TermViewTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.TermView

  defp coloured(text), do: text |> TermView.highlight() |> Enum.reject(&match?({nil, _}, &1))

  test "the pieces join back to the original text" do
    text = ~S({ok, [a, 'B', "s{"], #{a => <<1>>}, #Ref<0.1.2.3>, <0.80.0>})
    assert text |> TermView.highlight() |> Enum.map_join(&elem(&1, 1)) == text
  end

  test "atoms, strings and commas get their own colours" do
    assert coloured(~s({ok, [a, 'B', "s"]})) == [
             {"tok-curly", "{"},
             {"tok-atom", "ok"},
             {"tok-comma", ","},
             {"tok-square", "["},
             {"tok-atom", "a"},
             {"tok-comma", ","},
             {"tok-atom", "'B'"},
             {"tok-comma", ","},
             {"tok-string", ~s("s")},
             {"tok-square", "]"},
             {"tok-curly", "}"}
           ]
  end

  test "a bracket inside a string is not coloured" do
    assert coloured(~s("{x}")) == [{"tok-string", ~s("{x}")}]
  end

  test "a map closes with its own colour, binaries with theirs" do
    assert coloured("\#{a => <<1>>}") == [
             {"tok-map", "\#{"},
             {"tok-atom", "a"},
             {"tok-bin", "<<"},
             {"tok-bin", ">>"},
             {"tok-map", "}"}
           ]
  end

  test "Elixir structs are maps, and refs and pids are refs" do
    assert coloured(~s(%Foo.Bar{x: 1})) == [
             {"tok-map", "%Foo.Bar{"},
             {"tok-atom", "x"},
             {"tok-map", "}"}
           ]

    assert coloured("#Ref<0.1.2.3>") == [{"tok-ref", "#Ref<0.1.2.3>"}]
    assert coloured("<0.80.0>") == [{"tok-ref", "<0.80.0>"}]
  end

  test "unknown views fall back to pretty" do
    assert TermView.parse_view("tree") == :tree
    assert TermView.parse_view("raw") == :raw
    assert TermView.parse_view("bogus") == :pretty
  end
end
