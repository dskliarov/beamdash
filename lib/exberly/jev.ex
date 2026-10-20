defmodule Exberly.Jev do
  @moduledoc """
  Client for TypeSafe's Jev model (`POST /v1/systemone`), shared by the
  process and GC advisors. One request asks one Choice question about a
  `state` of derived, non-identifying measurements.

  Per TypeSafe's docs, an answer carries `choice`, `probabilities` (summing
  to 1 over every option) and `confidence`, which describes how peaked the
  distribution is, not how likely the answer is to be right. So the answer
  is never replaced on low confidence: when the top two options are close,
  both are shown. Whether there is enough evidence to ask at all is
  decided locally by the advisors, before any request.

  Configuration (`config/runtime.exs`): `JEV_ENABLED` (`false` hides
  every Jev element and blocks every request), `TYPESAFE_API_KEY`,
  `TYPESAFE_MODEL` (default: the pinned `#{"jev-1.13.0"}`; `jev-latest`
  changes when TypeSafe ships a release) and `TYPESAFE_CACERTFILE`.
  """

  @endpoint ~c"https://api.typesafe.ai/v1/systemone"
  @default_model "jev-1.13.0"
  # top two closer than this: show both
  @close 0.15

  def endpoint, do: List.to_string(endpoint_url())

  # TYPESAFE_ENDPOINT points elsewhere (a stand-in for testing); default
  # TypeSafe's API
  defp endpoint_url do
    case config()[:endpoint] do
      url when is_binary(url) and url != "" -> String.to_charlist(url)
      _ -> @endpoint
    end
  end

  def default_model, do: @default_model

  def configured? do
    key = config()[:api_key]
    is_binary(key) and String.trim(key) != ""
  end

  def model, do: config()[:model] || @default_model

  @doc """
  Whether Jev is enabled in the configuration (`JEV_ENABLED`, default
  true). Disabled, exberly never calls it and shows nothing of it.
  """
  def enabled_in_config?, do: config()[:enabled] != false

  @doc "Enabled in the configuration and an API key set: only then does the UI show Jev."
  def available?, do: enabled_in_config?() and configured?()

  @doc """
  Asks one Choice question. `choices` is `%{key => %{label, what, not_for}}`.
  Returns `{:ok, answer}` (see `parse/2`) or `{:error, user_message}`.
  Options: `:api_key`, `:model`, `:request` (an `:httpc.request/4`-like fun).
  """
  def ask(state, question, choices, opts \\ []) do
    with {:ok, %{"next_step" => answer}} <-
           ask_many(state, %{"next_step" => {question, choices}}, opts),
         do: {:ok, answer}
  end

  @doc """
  Asks several Choice questions about one state in one request (Jev
  answers them in parallel): `questions` is `%{id => {instructions,
  choices}}`. Returns `{:ok, %{id => answer}}`; any invalid answer fails
  the whole request.
  """
  def ask_many(state, questions, opts \\ []) do
    cond do
      not enabled_in_config?() ->
        {:error, "Jev is disabled in the configuration."}

      not Exberly.Settings.jev_enabled?() ->
        {:error, "Jev is off in Settings."}

      not key?(Keyword.get(opts, :api_key, config()[:api_key])) ->
        {:error, "Set TYPESAFE_API_KEY and restart exberly to use Jev."}

      true ->
        request(state, questions, opts)
    end
  end

  defp key?(key), do: is_binary(key) and String.trim(key) != ""

  defp request(state, questions, opts) do
    key = Keyword.get(opts, :api_key, config()[:api_key])
    model = Keyword.get(opts, :model, model())
    request = Keyword.get(opts, :request, &:httpc.request/4)

    payload = %{
      model: model,
      state: state,
      questions:
        Map.new(questions, fn {id, {instructions, choices}} ->
          {id, %{type: "choice", instructions: instructions, criteria: criteria(choices)}}
        end)
    }

    with {:ok, ssl} <- tls_options(),
         {:ok, {{_, 200, _}, _, body}} <-
           request.(
             :post,
             {endpoint_url(), [{~c"authorization", String.to_charlist("Bearer " <> key)}],
              ~c"application/json", Jason.encode!(payload)},
             [timeout: 15_000, connect_timeout: 5_000, autoredirect: false, ssl: ssl],
             body_format: :binary
           ),
         {:ok, decoded} <- Jason.decode(body) do
      parse_all(decoded, questions)
    else
      {:ok, {{_, code, _}, _, _}} ->
        {:error, http_error(code)}

      {:error, :tls_unavailable} ->
        {:error, "TLS certificates unavailable. Set TYPESAFE_CACERTFILE to a trusted CA bundle."}

      _ ->
        {:error, "Jev could not be reached or returned an invalid response. Try again later."}
    end
  end

  defp parse_all(%{"model" => model, "answers" => answers}, questions)
       when is_binary(model) and is_map(answers) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, {_instructions, choices}}, {:ok, acc} ->
      case parse(%{"model" => model, "answers" => %{"next_step" => answers[id]}}, choices) do
        {:ok, answer} -> {:cont, {:ok, Map.put(acc, id, answer)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_all(_, _), do: {:error, "Jev returned an invalid answer."}

  @doc "Choices as Jev criteria: what each option covers and what it does not."
  def criteria(choices) do
    Map.new(choices, fn {key, c} ->
      {key, %{option: c.label, what: c.what, not_for: c.not_for}}
    end)
  end

  @doc """
  Validates a response against the options asked and returns
  `%{model, choice, confidence, ranking, alternative}`: `ranking` is every
  option, most probable first (`%{key, label, probability}`), and
  `alternative` the runner-up when it is within #{@close} of the top.
  """
  def parse(
        %{
          "model" => model,
          "answers" => %{
            "next_step" => %{
              "choice" => choice,
              "confidence" => confidence,
              "probabilities" => probabilities
            }
          }
        },
        choices
      )
      when is_binary(model) and is_number(confidence) and confidence >= 0 and confidence <= 1 and
             is_map(probabilities) do
    valid =
      Map.has_key?(choices, choice) and
        MapSet.new(Map.keys(probabilities)) == MapSet.new(Map.keys(choices)) and
        Enum.all?(probabilities, fn {_, p} -> is_number(p) and p >= 0 and p <= 1 end) and
        abs(Enum.sum(Map.values(probabilities)) - 1) < 0.01

    if valid do
      ranking =
        probabilities
        |> Enum.map(fn {key, p} -> %{key: key, label: choices[key].label, probability: p} end)
        |> Enum.sort_by(& &1.probability, :desc)

      [top | rest] = ranking

      alternative =
        case rest do
          [second | _] when top.probability - second.probability < @close -> second
          _ -> nil
        end

      {:ok,
       %{
         model: model,
         choice: choice,
         confidence: confidence,
         ranking: ranking,
         alternative: alternative
       }}
    else
      {:error, "Jev returned an invalid answer."}
    end
  end

  def parse(_, _), do: {:error, "Jev returned an invalid answer."}

  defp config, do: Application.get_env(:exberly, __MODULE__, [])

  defp tls_options do
    common = [
      verify: :verify_peer,
      depth: 5,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    file = config()[:cacertfile]

    roots =
      cond do
        is_binary(file) and file != "" -> [cacertfile: String.to_charlist(file)]
        File.regular?("/etc/ssl/cert.pem") -> [cacertfile: ~c"/etc/ssl/cert.pem"]
        true -> [cacerts: :public_key.cacerts_get()]
      end

    {:ok, common ++ roots}
  rescue
    _ -> {:error, :tls_unavailable}
  end

  # Status codes from TypeSafe's API reference; bodies are never shown.
  defp http_error(401), do: "Jev rejected the API key. Check TYPESAFE_API_KEY."
  defp http_error(413), do: "The measurements were too large for Jev."
  defp http_error(429), do: "Jev rate limit reached. Wait a moment and try again."
  defp http_error(529), do: "Jev is overloaded. Try again shortly."
  defp http_error(code) when code >= 500, do: "Jev is temporarily unavailable. Try again later."

  defp http_error(code) when code in [400, 422],
    do: "Jev rejected the request (#{code}). Check TYPESAFE_MODEL."

  defp http_error(code), do: "Jev rejected the request (#{code})."
end
