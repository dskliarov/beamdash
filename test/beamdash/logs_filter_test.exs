defmodule Beamdash.LogsFilterTest do
  use ExUnit.Case, async: true

  alias Beamdash.Logs.Filter

  defp entry(attrs) do
    Map.merge(
      %{level: :info, pid: nil, where: nil, message: "", meta: []},
      Map.new(attrs)
    )
  end

  describe "parse/1" do
    test "words, phrases and excludes" do
      assert Filter.parse(~s(Timeout -health "Repo Pool")) ==
               %{include: ["timeout", "repo pool"], exclude: ["health"]}
    end

    test "excluded phrase" do
      assert Filter.parse(~s(-"two words" a)) == %{include: ["a"], exclude: ["two words"]}
    end

    test "lone dash, empty quotes and blanks are ignored" do
      assert Filter.parse(~s(- "" a   )) == %{include: ["a"], exclude: []}
      assert Filter.parse("") == %{include: [], exclude: []}
    end
  end

  describe "match?/2" do
    test "case-insensitive" do
      assert Filter.match?(Filter.parse("TIMEOUT"), entry(message: "db timeout"))
    end

    test "all words must match" do
      f = Filter.parse("db timeout")
      assert Filter.match?(f, entry(message: "timeout in db"))
      refute Filter.match?(f, entry(message: "db ok"))
    end

    test "exclude wins" do
      f = Filter.parse("timeout -health")
      refute Filter.match?(f, entry(message: "health timeout"))
      assert Filter.match?(f, entry(message: "timeout"))
    end

    test "a phrase must be adjacent words" do
      f = Filter.parse(~s("repo pool"))
      assert Filter.match?(f, entry(message: "the Repo Pool is full"))
      refute Filter.match?(f, entry(message: "repo busy pool"))
    end

    test "matches on where, pid and meta values" do
      assert Filter.match?(Filter.parse("worker"), entry(where: "MyApp.Worker"))
      assert Filter.match?(Filter.parse("0.12.0"), entry(pid: "<0.12.0>"))
      assert Filter.match?(Filter.parse("abc"), entry(meta: [{"request_id", "ABC"}]))
      refute Filter.match?(Filter.parse("request_id"), entry(meta: [{"request_id", "abc"}]))
    end

    test "the empty filter matches" do
      assert Filter.match?(%{include: [], exclude: []}, entry(message: "anything"))
    end
  end

  describe "level_ok?/2" do
    test "minimum level" do
      assert Filter.level_ok?(:warning, %{level: :error})
      assert Filter.level_ok?(:warning, %{level: :warning})
      assert Filter.level_ok?(:warning, %{level: :emergency})
      refute Filter.level_ok?(:warning, %{level: :info})
      refute Filter.level_ok?(:warning, %{level: :notice})
      refute Filter.level_ok?(:warning, %{level: nil})
    end

    test "nil means all levels" do
      assert Filter.level_ok?(nil, %{level: nil})
      assert Filter.level_ok?(nil, %{level: :debug})
    end
  end

  describe "highlight/2" do
    test "marks case-insensitive occurrences, keeping the original case" do
      assert Filter.highlight("DB timeout after Timeout", Filter.parse("timeout")) ==
               [{:text, "DB "}, {:mark, "timeout"}, {:text, " after "}, {:mark, "Timeout"}]
    end

    test "no include terms" do
      assert Filter.highlight("abc", Filter.parse("-abc")) == [{:text, "abc"}]
    end

    test "leftmost-longest" do
      assert Filter.highlight("foobar x", Filter.parse("foo foobar")) ==
               [{:mark, "foobar"}, {:text, " x"}]
    end

    test "regex characters are literal" do
      assert Filter.highlight("a.b axb", Filter.parse("a.b")) ==
               [{:mark, "a.b"}, {:text, " axb"}]
    end

    test "no match and match at the very start and end" do
      assert Filter.highlight("abc", Filter.parse("z")) == [{:text, "abc"}]
      assert Filter.highlight("ab", Filter.parse("ab")) == [{:mark, "ab"}]
    end
  end
end
