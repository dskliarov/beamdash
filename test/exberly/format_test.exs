defmodule Exberly.FormatTest do
  use ExUnit.Case, async: true

  alias Exberly.{Format, Record}

  test "function references in each syntax" do
    assert Format.mfa({:gen_server, :loop, 7}, :erlang) == "gen_server:loop/7"
    assert Format.mfa({Exberly.Target, :init, 1}, :erlang) == "'Elixir.Exberly.Target':init/1"
    assert Format.mfa({:gen_server, :loop, 7}, :elixir) == ":gen_server.loop/7"
    assert Format.mfa({Exberly.Target, :init, 1}, :elixir) == "Exberly.Target.init/1"
    assert Format.mfa({:m, :"weird fun", 0}, :erlang) == "m:'weird fun'/0"
    assert Format.mfa({:m, :"weird fun", 0}, :elixir) == ":m.\"weird fun\"/0"
  end

  test "terms in each syntax" do
    term = {:ok, [1, 2], "hi", %{a: 1}}
    assert Format.term(term, :erlang) == ~s({ok,[1,2],<<"hi">>,\#{a => 1}})
    assert Format.term(term, :elixir) == ~s({:ok, [1, 2], "hi", %{a: 1}})
    assert Format.pid(self(), :erlang) =~ ~r/^<\d+\.\d+\.\d+>$/
    assert Format.pid(self(), :elixir) =~ ~r/^#PID<\d+\.\d+\.\d+>$/
  end

  test "records in each syntax, nested" do
    inner = Record.decode({:erlyberly_record, :item, [{:erlyberly_record_field, :sku, :a1}]})

    outer =
      Record.decode(
        {:erlyberly_record, :cart,
         [
           {:erlyberly_record_field, :items,
            [{:erlyberly_record, :item, [{:erlyberly_record_field, :sku, :a1}]}]}
         ]}
      )

    assert Format.term(inner, :erlang) == "#item{sku = a1}"
    assert Format.term(outer, :erlang) == "#cart{items = [#item{sku = a1}]}"
    assert Format.term(outer, :elixir) == "#cart{items: [#item{sku: :a1}]}"
    assert Format.pretty(outer, :erlang) == "#cart{items = [#item{sku = a1}]}"
  end

  test "label prefers the registered name" do
    assert Format.label(%{registered_name: :code_server, initial_call: {:erlang, :apply, 2}}) ==
             "code_server"

    assert Format.label(%{registered_name: nil, initial_call: {:erlang, :apply, 2}}, :elixir) ==
             ":erlang.apply/2"

    assert Format.name(Exberly.Target, :elixir) == "Exberly.Target"
    assert Format.name(Exberly.Target, :erlang) == "Elixir.Exberly.Target"
  end

  test "traced calls, results and durations" do
    entry = %{
      mod: :lists,
      fun: :reverse,
      arity: 1,
      args: [[1, 2, 3]],
      call_us: 1_000,
      return_us: 1_250
    }

    assert Format.call(entry, :erlang) == "lists:reverse([1,2,3])"
    assert Format.call(entry, :elixir) == ":lists.reverse([1, 2, 3])"

    assert Format.call(%{entry | mod: Exberly.Target, fun: :status, args: []}, :elixir) ==
             "Exberly.Target.status()"

    assert Format.result({:return, :ok}, :elixir) == ":ok"
    assert Format.result({:exception, {:error, :badarg}}, :erlang) == "error:badarg"
    assert Format.result({:exception, {:error, :badarg}}, :elixir) == "error: :badarg"
    assert Format.result(:pending) == "…"
    assert Format.duration(entry) == "250 µs"
    assert Format.duration(%{entry | return_us: 2_501_000}) == "2.5 s"
    assert Format.duration(%{entry | return_us: nil}) == ""
    assert Format.time(0) == "00:00:00.000"
  end

  test "long terms are truncated in both syntaxes" do
    long = List.duplicate(String.duplicate("x", 30), 20)

    for syntax <- [:erlang, :elixir] do
      text = Format.term(long, syntax)
      assert String.length(text) == 160
      assert String.ends_with?(text, "…")
    end
  end

  test "numbers and bytes" do
    assert Format.number(1_234_567) == "1,234,567"
    assert Format.number(999) == "999"
    assert Format.bytes(512) == "512 B"
    assert Format.bytes(2048) == "2.0 KB"
    assert Format.bytes(5 * 1_048_576) == "5.0 MB"
  end
end
