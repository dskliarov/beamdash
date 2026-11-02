defmodule Beamdash.LogsFilterFieldTest do
  use ExUnit.Case, async: true

  alias Beamdash.Logs.Filter

  defp entry(message), do: %{message: message, where: nil, pid: nil, meta: []}

  test "a key=value term matches a field of an Erlang term" do
    f = Filter.parse("count=3")
    assert Filter.match?(f, entry("state #st{count = 3,name = fixture}"))
    refute Filter.match?(f, entry("state #st{count = 4,name = fixture}"))
  end

  test "a key=value term matches a field of a JSON line" do
    f = Filter.parse("level=info")
    assert Filter.match?(f, entry(~S|{"level":"info","count":3}|))
    refute Filter.match?(f, entry(~S|{"level":"warn","count":3}|))
  end

  test "a key=value term still matches the text of a logfmt line" do
    assert Filter.match?(Filter.parse("user=42"), entry("request user=42 took 5 ms"))
  end

  test "an excluded key=value term removes the lines that have that field" do
    f = Filter.parse("-count=3")
    refute Filter.match?(f, entry("state #st{count = 3,name = fixture}"))
    assert Filter.match?(f, entry("state #st{count = 4,name = fixture}"))
  end

  test "pair_term quotes a pair with spaces so it stays one term" do
    assert Filter.pair_term("count=3") == "count=3"
    assert Filter.pair_term("name=my value") == ~s("name=my value")

    f = Filter.parse(Filter.pair_term("name=my value"))
    assert Filter.match?(f, entry(~S|{"name":"my value"}|))
  end
end
