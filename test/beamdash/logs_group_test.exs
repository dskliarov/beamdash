defmodule Beamdash.LogsGroupTest do
  use ExUnit.Case, async: true

  alias Beamdash.Logs.Group

  defp e(id, message, attrs \\ []) do
    Map.merge(
      %{
        id: id,
        at: DateTime.add(~U[2026-10-23 12:00:00Z], id, :second),
        level: :info,
        pid: nil,
        where: nil,
        message: message,
        meta: [],
        raw: message
      },
      Map.new(attrs)
    )
  end

  defp same_key?(a, b), do: Group.key(e(1, a)) == Group.key(e(2, b))

  describe "key/1" do
    test "numbers are masked" do
      assert same_key?("cache miss for key user:4812", "cache miss for key user:77")
      assert same_key?("took 12ms", "took 340ms")
      assert same_key?("took 1.5s", "took 22.25s")
    end

    test "pids, refs, uuids, hex ids and timestamps are masked" do
      assert same_key?("pid <0.12.0> died", "pid <0.99.0> died")
      assert same_key?("ref #Reference<0.1.2.3> lost", "ref #Reference<0.9.8.7> lost")

      assert same_key?(
               "id 123e4567-e89b-12d3-a456-426614174000 gone",
               "id 9b2f6c1a-0000-4abc-8def-123456789abc gone"
             )

      assert same_key?("trace deadbeef01 end", "trace cafebabe02 end")
      assert same_key?("at 2026-10-23T12:04:01.233Z x", "at 2026-10-24 01:02:03+02:00 x")
    end

    test "a hex-looking word without digits is not masked" do
      refute same_key?("got deadbeef", "got cafebabe")
    end

    test "masked output has no stray #s from numbers inside timestamps" do
      {_, _, masked} = Group.key(e(1, "at 2026-10-23T12:04:01Z done"))
      assert masked == "at # done"
    end

    test "different text differs" do
      refute same_key?("a", "b")
    end

    test "level and where are part of the key" do
      refute Group.key(e(1, "m")) == Group.key(e(2, "m", level: :error))
      refute Group.key(e(1, "m")) == Group.key(e(2, "m", where: "X"))
    end
  end

  describe "mask_spans/1" do
    test "splits text and variable parts" do
      assert Group.mask_spans("user:4812 took 12ms") ==
               [{:text, "user:"}, {:var, "4812"}, {:text, " took "}, {:var, "12"}, {:text, "ms"}]
    end

    test "segments concatenate back to the message" do
      msg = "x 2026-10-23T12:04:01Z <0.1.0> #Reference<0.1.2.3> deadbeef01 deadbeef 7.5 ok"
      spans = Group.mask_spans(msg)
      assert Enum.map_join(spans, fn {_, s} -> s end) == msg
      assert {:var, "2026-10-23T12:04:01Z"} in spans
      assert {:var, "<0.1.0>"} in spans
      assert {:var, "deadbeef01"} in spans
      assert {:var, "7.5"} in spans
      refute {:var, "deadbeef"} in spans
    end

    test "no variable parts gives a single text segment" do
      assert Group.mask_spans("plain") == [{:text, "plain"}]
    end
  end

  describe "group/1" do
    test "combines consecutive similar entries only" do
      c1 = e(1, "miss user:1")
      b = e(2, "other")
      c2 = e(3, "miss user:2")
      c3 = e(4, "miss user:3")

      assert [r1, r2, r3] = Group.group([c3, c2, b, c1])

      assert r1.count == 2
      assert r1.ids == [c3.id, c2.id]
      assert r1.entry == c3
      assert r1.id == "g-#{c2.id}"
      assert r1.first_at == c2.at
      assert r1.key == Group.key(c3)

      assert r2.count == 1
      assert r2.entry == b
      assert r2.ids == [b.id]
      assert r2.id == "g-#{b.id}"

      assert r3.count == 1
      assert r3.entry == c1
      assert r3.first_at == c1.at
    end

    test "empty" do
      assert Group.group([]) == []
    end
  end

  describe "add/2" do
    test "a similar entry increments the top row and keeps its id" do
      [row] = Group.group([e(1, "miss user:1")])
      newer = e(2, "miss user:2")

      assert [r] = Group.add([row], newer)
      assert r.count == 2
      assert r.id == row.id
      assert r.entry == newer
      assert r.ids == [2, 1]
      assert r.first_at == row.first_at
    end

    test "a different entry prepends a new row" do
      [row] = Group.group([e(1, "miss user:1")])
      other = e(2, "boom")

      assert [r, ^row] = Group.add([row], other)
      assert r.count == 1
      assert r.id == "g-2"
      assert r.ids == [2]
    end

    test "onto no rows" do
      assert [%{count: 1, id: "g-5"}] = Group.add([], e(5, "x"))
    end
  end
end
