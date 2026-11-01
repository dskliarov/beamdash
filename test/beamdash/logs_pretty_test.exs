defmodule Beamdash.LogsPrettyTest do
  use ExUnit.Case, async: true

  alias Beamdash.Logs.Pretty

  test "text without terms is returned unchanged" do
    assert Pretty.segments("cache miss for key user:1") == [{:text, "cache miss for key user:1"}]
  end

  test "a tuple inside text is normalised and the text around it kept" do
    assert Pretty.segments("got {ok,[1,2]} here") == [
             {:text, "got "},
             {:term, "{ok, [1, 2]}"},
             {:text, " here"}
           ]
  end

  test "a long term breaks one element per line" do
    text = "[" <> Enum.map_join(1..30, ", ", &Integer.to_string/1) <> "]"

    assert [{:term, term}] = Pretty.segments(text)
    assert String.starts_with?(term, "[\n  1,\n  2,\n")
    assert String.ends_with?(term, "\n  30\n]")
  end

  test "Elixir maps, keyword and arrow keys, and structs" do
    assert [{:term, "%{a: 1, \"b\" => [2]}"}] = Pretty.segments(~S|%{a: 1, "b" => [2]}|)
    assert [{:term, "%Beamdash.Worker{id: 3}"}] = Pretty.segments("%Beamdash.Worker{id: 3}")
  end

  test "Erlang maps" do
    assert [{:term, ~S|#{a => 1}|}] = Pretty.segments(~S|#{a => 1}|)
  end

  test "an incomplete term is left as it was" do
    assert Pretty.segments("oops {ok, 1") == [{:text, "oops {ok, 1"}]
  end

  test "pids and references are not parsed" do
    text = "pid <0.86.0> and #PID<0.1.0>"
    assert Pretty.segments(text) == [{:text, text}]
  end

  test "parsing creates no atoms from the text" do
    name = "pretty_probe_#{System.unique_integer([:positive])}"
    refute atom_exists?(name)

    Pretty.segments("{#{name}, 1}")

    refute atom_exists?(name)
  end

  test "messages over the size cap are not parsed" do
    text = String.duplicate("a {ok, 1} ", 1_000)
    assert Pretty.segments(text) == [{:text, text}]
  end

  test "deep nesting does not crash" do
    text = String.duplicate("[", 100) <> String.duplicate("]", 100)
    assert [_ | _] = Pretty.segments(text)
  end

  defp atom_exists?(name) do
    String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end
