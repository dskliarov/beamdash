defmodule Exberly.JevTest do
  use ExUnit.Case, async: false
  alias Exberly.{GCAdvisor, Jev, ProcessAdvisor, Settings}
  alias Exberly.Jev.{Features, Scenarios}

  setup do
    previous = Settings.jev_enabled?()
    Settings.put_jev_enabled(true)
    on_exit(fn -> Settings.put_jev_enabled(previous) end)
    :ok
  end

  @choices %{
    "a" => %{label: "Option A", what: "covers a", not_for: "b"},
    "b" => %{label: "Option B", what: "covers b", not_for: "a"},
    "c" => %{label: "Option C", what: "covers c", not_for: "a"}
  }

  defp response(probabilities, confidence \\ 0.8) do
    {choice, _} = Enum.max_by(probabilities, &elem(&1, 1))

    %{
      "model" => "jev-1.13.0",
      "answers" => %{
        "next_step" => %{
          "type" => "choice",
          "choice" => choice,
          "confidence" => confidence,
          "probabilities" => probabilities
        }
      },
      "usage" => %{"input_tokens" => 300, "output_tokens" => 30}
    }
  end

  defp ok(body), do: fn _, _, _, _ -> {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}} end

  test "request follows the documented API: model, state, instructions, structured criteria" do
    request = fn method, {url, headers, type, body}, options, http_options ->
      assert method == :post
      assert url == ~c"https://api.typesafe.ai/v1/systemone"
      assert headers == [{~c"authorization", ~c"Bearer test-key"}]
      assert type == ~c"application/json"
      decoded = Jason.decode!(body)
      assert decoded["model"] == "jev-1.13.0"
      assert decoded["state"] == %{"x" => 1}
      q = decoded["questions"]["next_step"]
      assert q["type"] == "choice"
      assert q["instructions"]["question"] =~ "?"

      assert q["criteria"]["a"] == %{
               "option" => "Option A",
               "what" => "covers a",
               "not_for" => "b"
             }

      assert options[:timeout] == 15_000
      assert options[:autoredirect] == false
      assert options[:ssl][:verify] == :verify_peer
      assert http_options[:body_format] == :binary
      ok(Jason.encode!(response(%{"a" => 0.7, "b" => 0.2, "c" => 0.1}))).(1, 2, 3, 4)
    end

    assert {:ok, answer} =
             Jev.ask(%{x: 1}, %{question: "Which?"}, @choices,
               api_key: "test-key",
               model: "jev-1.13.0",
               request: request
             )

    assert answer.choice == "a"
    assert answer.alternative == nil
    assert [%{key: "a", label: "Option A"} | _] = answer.ranking
  end

  test "the model is pinned by default" do
    assert Jev.default_model() =~ ~r/^jev-\d+\.\d+\.\d+$/
  end

  test "a low-confidence answer is kept, and a close runner-up is offered beside it" do
    {:ok, close} = Jev.parse(response(%{"a" => 0.48, "b" => 0.42, "c" => 0.10}, 0.3), @choices)
    assert close.choice == "a"
    assert close.alternative.key == "b"

    {:ok, clear} = Jev.parse(response(%{"a" => 0.6, "b" => 0.3, "c" => 0.1}, 0.3), @choices)
    assert clear.choice == "a"
    assert clear.alternative == nil
  end

  test "invalid answers are rejected" do
    good = response(%{"a" => 1.0, "b" => 0.0, "c" => 0.0})
    assert {:error, _} = Jev.parse(%{}, @choices)

    assert {:error, _} =
             Jev.parse(put_in(good, ["answers", "next_step", "choice"], "z"), @choices)

    assert {:error, _} =
             Jev.parse(put_in(good, ["answers", "next_step", "confidence"], 1.5), @choices)

    assert {:error, _} =
             Jev.parse(
               put_in(good, ["answers", "next_step", "probabilities"], %{"a" => 1.0}),
               @choices
             )
  end

  test "no key, or Jev off, never makes a request" do
    never = fn _, _, _, _ -> flunk("request made") end
    assert {:error, msg} = Jev.ask(%{}, "q", @choices, api_key: "", request: never)
    assert msg =~ "TYPESAFE_API_KEY"
    Settings.put_jev_enabled(false)
    assert {:error, msg} = Jev.ask(%{}, "q", @choices, api_key: "k", request: never)
    assert msg =~ "off"
  end

  test "every documented error status gets a message without the upstream body or key" do
    for code <- [400, 401, 413, 415, 422, 429, 500, 529] do
      request = fn _, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", code, ~c"Error"}, [], "private upstream body"}}
      end

      assert {:error, message} =
               Jev.ask(%{}, "q", @choices, api_key: "secret-key", request: request)

      refute message =~ "private"
      refute message =~ "secret-key"
    end

    for request <- [ok("not json"), fn _, _, _, _ -> {:error, :timeout} end] do
      assert {:error, _} = Jev.ask(%{}, "q", @choices, api_key: "k", request: request)
    end
  end

  describe "features" do
    test "slope, change, shares, ratio and rank" do
      assert Features.slope([{0, 0}, {1, 10}, {2, 20}]) == 10.0
      assert Features.slope([{0, 5}]) == nil
      assert Features.change_pct([100, 150, 200]) == 100.0
      assert Features.change_pct([0, 10]) == nil
      assert Features.share(25, 100) == 25.0
      assert Features.ratio(300, 100) == 3.0
      assert Features.top_pct([1, 2, 3, 4], 4) == 25.0
      assert Features.thin(Enum.to_list(1..30), 10) |> List.last() == 30
    end

    test "wait category never reveals the function" do
      assert Features.wait_category(:waiting, {:gen_server, :loop, 7}) == :otp_receive_loop
      # a call waiting for a reply is not idleness
      assert Features.wait_category(:waiting, {:gen, :do_call, 4}) == :call_reply
      assert Features.wait_category(:waiting, {:my_secret_mod, :f, 1}) == :application_code
      assert Features.wait_category(:waiting, {:erlang, :hibernate, 3}) == :hibernated
      assert Features.wait_category(:running, {:my_secret_mod, :f, 1}) == :running
    end
  end

  describe "scenarios" do
    test "every scenario builds a ready, non-identifying state with valid expected answers" do
      for s <- Scenarios.all() do
        {advisor, choices} =
          if s.advisor == :process,
            do: {ProcessAdvisor, ProcessAdvisor.choices()},
            else: {GCAdvisor, GCAdvisor.choices()}

        assert Enum.all?(s.expect, &Map.has_key?(choices, &1)), s.name
        assert s.evidence.observed_samples >= 15
        assert s.evidence.observed_window_s >= 15
        text = Jason.encode!(s.evidence)
        refute text =~ "pid"
        refute text =~ "my_app_client", s.name
        refute text =~ "gen_server:loop"

        probabilities =
          Map.new(choices, fn {k, _} -> {k, if(k == hd(s.expect), do: 1.0, else: 0.0)} end)

        assert {:ok, advice} =
                 advisor.analyze(s.evidence,
                   api_key: "k",
                   request: ok(Jason.encode!(response(probabilities)))
                 )

        assert advice.title == choices[hd(s.expect)].label
        assert advice.samples == s.evidence.observed_samples
      end
    end

    test "the derived facts carry the signal each scenario is about" do
      by_name = Map.new(Scenarios.all(), &{&1.name, &1.evidence})
      assert by_name["message backlog"].mailbox.queue_growth_per_s > 50
      assert by_name["hot loop"].node.reductions_rate_rank_top_pct < 5
      assert by_name["heap growth"].memory.change_over_window_pct > 100
      assert by_name["binary retention"].memory.binary_bytes_per_process_memory_byte > 100
      assert by_name["idle memory hog"].node.memory_rank_top_pct < 5
      assert by_name["blocked in application code"].process.waiting_in == :application_code
      assert by_name["blocked in a call to another process"].process.waiting_in == :call_reply
      assert by_name["allocation churn"].gc_trace.collections_per_s > 10
      assert by_name["not traced yet"].gc_trace == nil
    end
  end
end
