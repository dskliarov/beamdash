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
    text = String.duplicate("a {ok, 1} ", 7_000)
    assert Pretty.segments(text) == [{:text, text}]
  end

  test "opaque references inside a tuple keep the tuple formatted" do
    assert Pretty.segments(~S|{error,#Ref<0.1.2.3>}|) == [{:term, "{error, #Ref<0.1.2.3>}"}]
    assert Pretty.segments(~S|{pid,<0.86.0>,ok}|) == [{:term, "{pid, <0.86.0>, ok}"}]
    assert Pretty.segments(~S|{fun,#Fun<erl_eval.6.1>}|) == [{:term, "{fun, #Fun<erl_eval.6.1>}"}]
  end

  test "binaries are formatted as containers" do
    assert Pretty.segments(~S|reply {bin,<<"ab">>}|) ==
             [{:text, "reply "}, {:term, ~S|{bin, <<"ab">>}|}]
  end

  test "a crash reason with nested binaries is one term" do
    text = ~S|{badarg,[{erlang,binary_to_atom,[<<"x">>,utf8],[]}]}|

    assert Pretty.segments(text) ==
             [{:term, ~S|{badarg, [{erlang, binary_to_atom, [<<"x">>, utf8], []}]}|}]
  end

  test "records print with their field names" do
    assert Pretty.segments("state #st{count = 1,name = fixture}") ==
             [{:text, "state "}, {:term, "#st{count = 1, name = fixture}"}]
  end

  test "a term over 8 KB is formatted" do
    text = "{data," <> Enum.map_join(1..2_000, ",", &Integer.to_string/1) <> "}"
    assert [{:term, _}] = Pretty.segments(text)
  end

  test "fields lists the map entries and key-value tuples of a message" do
    assert Pretty.fields(~S|state #st{count = 3,name = fixture}|) ==
             [{"count", "3"}, {"name", "fixture"}]

    assert Pretty.fields(~S|got {status,ok} and #{retries => 2}|) ==
             [{"status", "ok"}, {"retries", "2"}]
  end

  test "fields finds pairs inside nested terms" do
    assert Pretty.fields(~S|{req,[{user,{id,7}}]}|) ==
             [{"req", "[{user, {id, 7}}]"}, {"user", "{id, 7}"}, {"id", "7"}]
  end

  test "a JSON object's top-level keys are its fields, with non-strings encoded" do
    json = ~S|{"level":"info","count":3,"meta":{"a":1}}|

    assert Pretty.fields(json) == [{"count", "3"}, {"level", "info"}, {"meta", ~S|{"a":1}|}]
    assert Pretty.fields_match?([{"level", "info"}], json)
    refute Pretty.fields_match?([{"level", "warn"}], json)
  end

  test "a message without a key-value term has no fields" do
    assert Pretty.fields("plain text 42") == []
    assert Pretty.fields("{1,2,3}") == []
  end

  test "fields_match? needs every filter pair" do
    text = ~S|state #st{count = 3,name = fixture}|
    assert Pretty.fields_match?([], text)
    assert Pretty.fields_match?([{"count", "3"}], text)
    assert Pretty.fields_match?([{"count", "3"}, {"name", "fixture"}], text)
    refute Pretty.fields_match?([{"count", "4"}], text)
    refute Pretty.fields_match?([{"count", "3"}], "no terms here")
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
