defmodule Beamdash.SeqAdvisor do
  @moduledoc """
  The pattern of a seq trace, from Jev: request storm, fan-out, chatty
  exchange, deep chain, slow responder or normal flow. beamdash computes
  the shape of the recorded messages (counts by kind, call→reply latency,
  unanswered calls, fan-out and fan-in, concentration on one process,
  round trips, causal-chain depth, burstiness); no pids, names or message
  contents are sent.
  """
  alias Beamdash.Jev
  alias Beamdash.Jev.Features, as: F

  @min_messages 10

  @choices %{
    "request_storm" => %{
      label: "Request storm",
      what:
        "Many senders send to one process at a high rate: traffic concentrates on it and it receives far more than it sends. Look at that process's queue and how fast it handles requests.",
      not_for: "Traffic spread evenly, or a modest rate."
    },
    "fan_out" => %{
      label: "Fan-out",
      what:
        "One process sends the same kind of message to many receivers: each request is multiplied. Check whether all receivers need it.",
      not_for: "One-to-one requests and replies."
    },
    "chatty_exchange" => %{
      label: "Chatty exchange",
      what:
        "Two processes trade many small messages back and forth (many round trips per request). Batching or moving the work into one process may help.",
      not_for: "One request and one reply per operation."
    },
    "deep_chain" => %{
      label: "Deep call chain",
      what:
        "Each request passes through a long chain of processes before it completes; every hop adds latency and a failure point.",
      not_for: "Chains of one or two hops."
    },
    "slow_responder" => %{
      label: "Slow responder",
      what:
        "Calls wait long for their replies, or replies are missing: the called process is slow, busy or blocked, and its callers wait.",
      not_for: "Fast replies to every call."
    },
    "normal_flow" => %{
      label: "Normal flow",
      what:
        "Requests and replies pair up quickly, with modest rates and short chains: nothing stands out in this trace.",
      not_for: "Any of the patterns above clearly present."
    }
  }

  @question %{
    question:
      "Which message-flow pattern best describes this seq trace of an Erlang/Elixir system?",
    rules: [
      "Counts are messages sent; shares are percentages of all messages; latencies are milliseconds.",
      "A gen_server call is a request message followed by a reply to the caller.",
      "Null means not measured."
    ]
  }

  def choices, do: @choices
  def min_messages, do: @min_messages

  @doc "`{:ready, n}` with at least #{@min_messages} messages sent, else `{:collecting, n, needed, \"messages\"}`."
  def readiness(events) do
    n = Enum.count(events, &(&1.type == :send))
    if n >= @min_messages, do: {:ready, n}, else: {:collecting, n, @min_messages, "messages"}
  end

  def analyze(evidence, opts \\ []) do
    with {:ok, answer} <- Jev.ask(evidence, @question, @choices, opts) do
      c = @choices[answer.choice]

      {:ok,
       Map.merge(answer, %{
         title: c.label,
         description: c.what,
         samples: evidence.messages,
         window_s: evidence.observed_window_s,
         processes: evidence.processes,
         at: DateTime.utc_now()
       })}
    end
  end

  @doc "The state sent to Jev for seq trace `events` (`Beamdash.SeqTracer.events/0`)."
  def evidence(events) do
    sends = events |> Enum.filter(&(&1.type == :send)) |> Enum.sort_by(&(&1.timestamp_us || 0))
    n = length(sends)
    times = sends |> Enum.map(& &1.timestamp_us) |> Enum.filter(&is_integer/1)
    span_us = if times == [], do: 0, else: Enum.max(times) - Enum.min(times)
    kinds = Enum.frequencies_by(sends, &kind(&1.message))
    {latencies, unanswered} = call_latencies(sends)
    # fan-out and fan-in count requests, casts and other messages: a
    # server replying to many callers is not fanning out
    requests = Enum.reject(sends, &(kind(&1.message) == :reply))
    by_sender = Enum.group_by(sends, & &1.from, & &1.to)
    by_receiver = Enum.group_by(sends, & &1.to, & &1.from)
    req_by_sender = Enum.group_by(requests, & &1.from, & &1.to)
    req_by_receiver = Enum.group_by(requests, & &1.to, & &1.from)
    # messages between each pair of processes, both directions
    per_pair = Enum.frequencies_by(sends, &Enum.sort([&1.from, &1.to]))
    depths = chain_depths(sends)

    %{
      messages: n,
      processes: sends |> Enum.flat_map(&[&1.from, &1.to]) |> Enum.uniq() |> length(),
      observed_window_s: Float.round(span_us / 1_000_000, 2),
      messages_per_s: if(span_us > 0, do: Float.round(n / (span_us / 1_000_000), 1)),
      kinds: %{
        calls: kinds[:call] || 0,
        replies: kinds[:reply] || 0,
        casts: kinds[:cast] || 0,
        other: kinds[:other] || 0
      },
      calls: %{
        unanswered: unanswered,
        reply_latency_ms_mean: latencies |> F.mean() |> ms(),
        reply_latency_ms_max: latencies |> F.max_of() |> ms()
      },
      concentration: %{
        top_receiver_share_pct: F.share(max_count(by_receiver), n),
        top_sender_share_pct: F.share(max_count(by_sender), n),
        max_fan_out: max_distinct(req_by_sender),
        max_fan_in: max_distinct(req_by_receiver)
      },
      exchange: %{
        process_pairs: map_size(per_pair),
        max_messages_between_one_pair: per_pair |> Map.values() |> Enum.max(fn -> 0 end),
        mean_messages_per_pair: per_pair |> Map.values() |> F.mean()
      },
      chains: %{
        longest: F.max_of(depths),
        mean: F.mean(depths)
      },
      burstiness: burstiness(times)
    }
  end

  defp kind({:"$gen_call", _from, _req}), do: :call
  defp kind({:"$gen_cast", _req}), do: :cast
  defp kind({[:alias | ref], _reply}) when is_reference(ref), do: :reply
  defp kind({ref, _reply}) when is_reference(ref), do: :reply
  defp kind(_), do: :other

  defp call_ref({:"$gen_call", {_pid, [:alias | ref]}, _}) when is_reference(ref), do: ref
  defp call_ref({:"$gen_call", {_pid, ref}, _}) when is_reference(ref), do: ref
  defp call_ref(_), do: nil

  defp reply_ref({[:alias | ref], _}) when is_reference(ref), do: ref
  defp reply_ref({ref, _}) when is_reference(ref), do: ref
  defp reply_ref(_), do: nil

  # call → reply times in microseconds, and calls with no reply
  defp call_latencies(sends) do
    {open, latencies} =
      Enum.reduce(sends, {%{}, []}, fn e, {open, lat} ->
        cond do
          ref = call_ref(e.message) ->
            {Map.put(open, ref, e.timestamp_us), lat}

          (ref = reply_ref(e.message)) && Map.has_key?(open, ref) ->
            t0 = open[ref]

            lat =
              if is_integer(t0) and is_integer(e.timestamp_us),
                do: [e.timestamp_us - t0 | lat],
                else: lat

            {Map.delete(open, ref), lat}

          true ->
            {open, lat}
        end
      end)

    {latencies, map_size(open)}
  end

  defp ms(nil), do: nil
  defp ms(us), do: Float.round(us / 1000, 2)

  defp max_count(groups),
    do: groups |> Enum.map(fn {_k, v} -> length(v) end) |> Enum.max(fn -> 0 end)

  defp max_distinct(groups),
    do:
      groups |> Enum.map(fn {_k, v} -> v |> Enum.uniq() |> length() end) |> Enum.max(fn -> 0 end)

  # seq_trace serials are {previous, current}: follow them back to measure
  # how many hops each message is from the start of its chain
  defp chain_depths(sends) do
    prev_of =
      for %{serial: {p, c}} <- sends, is_integer(c), into: %{}, do: {c, p}

    depth = fn depth, c, seen ->
      case prev_of[c] do
        p when is_integer(p) and p != c ->
          if MapSet.member?(seen, p) or not Map.has_key?(prev_of, p),
            do: 1,
            else: 1 + depth.(depth, p, MapSet.put(seen, p))

        _ ->
          1
      end
    end

    for %{serial: {_p, c}} <- sends, is_integer(c), do: depth.(depth, c, MapSet.new([c]))
  end

  # the busiest 100 ms against the average 100 ms
  defp burstiness(times) when length(times) < 2, do: nil

  defp burstiness(times) do
    t0 = Enum.min(times)
    buckets = Enum.frequencies_by(times, &div(&1 - t0, 100_000))
    slots = div(Enum.max(times) - t0, 100_000) + 1
    peak = buckets |> Map.values() |> Enum.max()

    %{
      busiest_100ms_messages: peak,
      busiest_vs_average: Float.round(peak / (length(times) / slots), 1)
    }
  end
end
