defmodule Beamdash.LogsParseTest do
  use ExUnit.Case, async: true

  alias Beamdash.Logs.Parse

  test "kubectl timestamp is stripped into `at`, truncated to microseconds" do
    text = "2026-10-23T12:04:01.233456789Z 12:04:01.233 [warning] cache miss"
    e = Parse.line(text)

    assert e.at == ~U[2026-10-23 12:04:01.233456Z]
    assert e.level == :warning
    assert e.message == "cache miss"
    assert e.raw == text
    assert e.pid == nil
    assert e.where == nil
    assert e.meta == []
  end

  test "elixir logger line with a time prefix" do
    e = Parse.line("12:04:01.233 [info] QUERY OK db=1.2ms")
    assert e.level == :info
    assert e.message == "QUERY OK db=1.2ms"
    assert e.at == nil
  end

  test "bare level prefix" do
    assert Parse.line("[error] boom").level == :error
    assert Parse.line("[error] boom").message == "boom"
  end

  test "level aliases" do
    assert Parse.line("[warn] x").level == :warning
    assert Parse.line("[err] x").level == :error
    assert Parse.line("[nonsense] x").level == nil
  end

  test "json line" do
    e =
      Parse.line(
        ~s({"level":"error","msg":"boom","module":"MyApp.Worker","request_id":"abc","n":3})
      )

    assert e.level == :error
    assert e.message == "boom"
    assert e.where == "MyApp.Worker"
    assert {"request_id", "abc"} in e.meta
    assert {"n", "3"} in e.meta
    refute Enum.any?(e.meta, fn {k, _} -> k in ["level", "msg", "module"] end)
  end

  test "json line with severity, message, logger, pid and a non-string value" do
    e =
      Parse.line(
        ~s(2026-10-23T12:00:00Z {"severity":"WARN","message":"hi","logger":"l","pid":"<0.1.0>","x":{"a":1}})
      )

    assert e.at == ~U[2026-10-23 12:00:00Z]
    assert e.level == :warning
    assert e.message == "hi"
    assert e.where == "l"
    assert e.pid == "<0.1.0>"
    assert e.meta == [{"x", ~s({"a":1})}]
  end

  test "invalid json falls back to plain text" do
    e = Parse.line("{not json")
    assert e.level == nil
    assert e.message == "{not json"
  end

  test "plain text" do
    e = Parse.line("plain text")
    assert e.level == nil
    assert e.message == "plain text"
    assert e.raw == "plain text"
  end

  test "continuation?" do
    assert Parse.continuation?("    (stdlib) gen_server.erl:1")
    assert Parse.continuation?("\tat foo")
    assert Parse.continuation?("2026-10-23T12:04:01Z     at foo")
    refute Parse.continuation?("[info] x")
    refute Parse.continuation?("2026-10-23T12:04:01Z [info] x")
  end

  test "phoenix default format: metadata between the time and the level" do
    e = Parse.line("08:12:01.123 request_id=GBxYz [info] GET /api")
    assert e.level == :info
    assert e.message == "GET /api"
    assert {"request_id", "GBxYz"} in e.meta

    e = Parse.line("12:00:00.000 a=1 b=2 [warning] y")
    assert e.level == :warning
    assert e.message == "y"
    assert e.meta == [{"a", "1"}, {"b", "2"}]

    e = Parse.line("[error] x")
    assert e.level == :error
    assert e.message == "x"
    assert e.meta == []

    e = Parse.line("2026-10-23T12:00:00Z 08:12:01.123 request_id=Q [debug] z")
    assert e.level == :debug
    assert e.meta == [{"request_id", "Q"}]
  end

  test "json module and pid must be strings, other values become nil" do
    e = Parse.line(~s({"msg":"m","module":false,"pid":3}))
    assert e.where == nil
    assert e.pid == nil
    assert e.message == "m"

    e = Parse.line(~s({"msg":"m","logger":{"a":1}}))
    assert e.where == nil
  end

  describe "other common formats get their level" do
    for {line, level, message} <- [
          # date and time before the level (Logger `$date $time`)
          {"2026-10-24 10:00:00.123 [info] date and time", :info, "date and time"},
          {"2026-10-24T10:00:00.123Z 2026-10-24 10:00:00.123 [info] both stamps", :info,
           "both stamps"},
          {"10:00:00 [warning] no milliseconds", :warning, "no milliseconds"},
          # ANSI colours (Logger `colors: [enabled: true]` in a container)
          {"\e[22m10:00:00.123 [info] coloured\e[0m", :info, "coloured"},
          # logfmt
          {~s(level=info msg="logfmt line" ts=2026), :info, "logfmt line"},
          {"time=2026-10-24T10:00:00Z level=warn msg=short", :warning, "short"},
          # a bare level word first
          {"INFO 2026-10-24 10:00:00 java style", :info, "2026-10-24 10:00:00 java style"},
          {"ERROR: something failed", :error, "something failed"},
          # other JSON level keys
          {~s({"log.level":"info","message":"ecs"}), :info, "ecs"},
          {~s({"lvl":"debug","msg":"lvl key"}), :debug, "lvl key"}
        ] do
      test inspect(line) do
        e = Parse.line(unquote(line))
        assert e.level == unquote(level)
        assert e.message == unquote(message)
        assert e.raw == unquote(line)
      end
    end

    test "logfmt keys other than level and msg become meta" do
      e = Parse.line(~s(time=2026-10-24T10:00:00Z level=info msg="hi there" user=42))
      assert {"user", "42"} in e.meta
      assert {"time", "2026-10-24T10:00:00Z"} in e.meta
    end

    test "a level word inside plain text is not a level" do
      for line <- ["something [info] in text", "user info updated", "a=[info] x"] do
        assert Parse.line(line).level == nil, line
      end
    end
  end
end
