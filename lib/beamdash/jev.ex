defmodule Beamdash.Jev do
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

  ## Backends

  The same requests can go to Kev instead (github.com/jaredpalmer/kev), a
  self-hosted model that serves TypeSafe's `/v1/systemone` API: `KEV_URL`
  (its server, e.g. `http://127.0.0.1:8009`) or `KEV_PORT` alone (a server
  on this machine, `http://127.0.0.1:<port>`) turns it on. The port saved in
  Settings (`Beamdash.Settings.kev_port/0`) replaces the URL's. `KEV_API_KEY` is
  sent only to it (when its server sets one), `KEV_MODEL` names the model
  shown and `KEV_TIMEOUT` (ms, default #{120_000}) allows for a slower
  machine. Each backend's key goes only to its own server.

  `backend/0` is the one in use: the one chosen in Settings, else
  `DECISION_BACKEND` (`jev` or `kev`), else Jev, else Kev, among those
  configured. `:backend` in a request's options overrides it.
  """

  @endpoint ~c"https://api.typesafe.ai/v1/systemone"
  @default_model "jev-1.13.0"
  @kev_default_model "kev-latest"
  @backends [:jev, :kev]
  @timeouts %{jev: 15_000, kev: 120_000}
  # top two closer than this: show both
  @close 0.15

  def endpoint(backend \\ backend()), do: List.to_string(endpoint_url(backend))

  # TYPESAFE_ENDPOINT points elsewhere (a stand-in for testing); default
  # TypeSafe's API. Kev: its server's /v1/systemone.
  defp endpoint_url(:jev) do
    case config()[:endpoint] do
      url when is_binary(url) and url != "" -> String.to_charlist(url)
      _ -> @endpoint
    end
  end

  defp endpoint_url(:kev) do
    base = String.trim_trailing(kev_url() || "", "/")

    if String.ends_with?(base, "/v1/systemone"),
      do: String.to_charlist(base),
      else: String.to_charlist(base <> "/v1/systemone")
  end

  @default_kev_host "127.0.0.1"

  # KEV_URL, else this machine at KEV_PORT; the port saved in Settings wins
  defp kev_url do
    url =
      cond do
        present?(config()[:kev_url]) -> String.trim(config()[:kev_url])
        port = port(config()[:kev_port]) -> "http://#{@default_kev_host}:#{port}"
        true -> nil
      end

    case {url, Beamdash.Settings.kev_port()} do
      {nil, _} -> nil
      {url, nil} -> url
      {url, port} -> url |> URI.parse() |> Map.put(:port, port) |> URI.to_string()
    end
  end

  @doc "The port of Kev's server, from `KEV_URL`, `KEV_PORT` or Settings; `nil` without Kev."
  def kev_port do
    case kev_url() do
      nil -> nil
      url -> URI.parse(url).port
    end
  end

  @doc "A TCP port from an integer or a string, or `nil`."
  def port(p) when is_integer(p) and p in 1..65_535, do: p

  def port(p) when is_binary(p) do
    case Integer.parse(String.trim(p)) do
      {n, ""} -> port(n)
      _ -> nil
    end
  end

  def port(_), do: nil

  def default_model, do: @default_model

  def backends, do: @backends

  @doc "Whether `backend` (default: the one in use) can be asked: Jev needs its key, Kev its URL."
  def configured?(backend \\ backend())
  def configured?(:jev), do: present?(config()[:api_key])
  def configured?(:kev), do: kev_url() != nil

  @doc "The backends that can be asked, Jev first."
  def configured_backends, do: Enum.filter(@backends, &configured?/1)

  @doc """
  The backend in use: chosen in Settings, else `DECISION_BACKEND`, else
  the first configured, else `:jev` (which then asks for a key).
  """
  def backend do
    [Beamdash.Settings.decision_backend(), config_backend() | @backends]
    |> Enum.find(:jev, &(&1 in @backends and configured?(&1)))
  end

  defp config_backend do
    case config()[:backend] do
      b when b in @backends -> b
      "kev" -> :kev
      "jev" -> :jev
      _ -> nil
    end
  end

  @doc "The name shown in the UI: \"Jev\" or \"Kev\"."
  def name(backend \\ backend())
  def name(:jev), do: "Jev"
  def name(:kev), do: "Kev"

  @doc "Where requests go, for \"What is sent to …\": TypeSafe, or Kev's host."
  def destination(backend \\ backend())
  def destination(:jev), do: "TypeSafe"
  def destination(:kev), do: "Kev at " <> (URI.parse(endpoint(:kev)).authority || "?")

  def model(backend \\ backend())
  def model(:jev), do: config()[:model] || @default_model
  def model(:kev), do: config()[:kev_model] || @kev_default_model

  defp api_key(:jev), do: config()[:api_key]
  defp api_key(:kev), do: config()[:kev_api_key]

  defp timeout(:kev), do: positive(config()[:kev_timeout]) || @timeouts.kev
  defp timeout(backend), do: @timeouts[backend]

  defp positive(n) when is_integer(n) and n > 0, do: n

  defp positive(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp positive(_), do: nil

  @doc """
  Whether Jev is enabled in the configuration (`JEV_ENABLED`, default
  true). Disabled, beamdash never calls it and shows nothing of it.
  """
  def enabled_in_config?, do: config()[:enabled] != false

  @doc "Enabled in the configuration and a backend configured: only then does the UI show Jev."
  def available?, do: enabled_in_config?() and configured_backends() != []

  @doc """
  Asks one Choice question. `choices` is `%{key => %{label, what, not_for}}`.
  Returns `{:ok, answer}` (see `parse/2`) or `{:error, user_message}`.
  Options: `:backend`, `:api_key`, `:model`, `:request` (an
  `:httpc.request/4`-like fun).
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
    backend = Keyword.get(opts, :backend, backend())
    key = Keyword.get(opts, :api_key, api_key(backend))

    cond do
      not enabled_in_config?() ->
        {:error, "Jev is disabled in the configuration."}

      not Beamdash.Settings.jev_enabled?() ->
        {:error, "#{name(backend)} is off in Settings."}

      backend == :jev and not present?(key) ->
        {:error, "Set TYPESAFE_API_KEY and restart beamdash to use Jev."}

      backend == :kev and not configured?(:kev) ->
        {:error, "Set KEV_URL and restart beamdash to use Kev."}

      true ->
        request(backend, key, state, questions, opts)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp request(backend, key, state, questions, opts) do
    model = Keyword.get(opts, :model, model(backend))
    request = Keyword.get(opts, :request, &:httpc.request/4)
    url = endpoint_url(backend)
    # Kev's server needs no key unless it sets KEV_API_KEY
    headers =
      if present?(key), do: [{~c"authorization", String.to_charlist("Bearer " <> key)}], else: []

    payload = %{
      model: model,
      state: state,
      questions:
        Map.new(questions, fn {id, {instructions, choices}} ->
          {id, %{type: "choice", instructions: instructions, criteria: criteria(choices)}}
        end)
    }

    with {:ok, ssl} <- transport_options(url),
         {:ok, {{_, 200, _}, _, body}} <-
           request.(
             :post,
             {url, headers, ~c"application/json", Jason.encode!(payload)},
             [timeout: timeout(backend), connect_timeout: 5_000, autoredirect: false] ++ ssl,
             body_format: :binary
           ),
         {:ok, decoded} <- Jason.decode(body) do
      parse_all(decoded, questions)
    else
      {:ok, {{_, code, _}, _, _}} ->
        {:error, http_error(backend, code)}

      {:error, :tls_unavailable} ->
        {:error, "TLS certificates unavailable. Set TYPESAFE_CACERTFILE to a trusted CA bundle."}

      {:error, :timeout} ->
        {:error, "#{name(backend)} did not answer within #{div(timeout(backend), 1000)} s."}

      _ ->
        {:error,
         "#{name(backend)} could not be reached or returned an invalid response. Try again later."}
    end
  end

  # TLS options only for https (a local Kev is plain http)
  defp transport_options(~c"https" ++ _) do
    with {:ok, ssl} <- tls_options(), do: {:ok, [ssl: ssl]}
  end

  defp transport_options(_url), do: {:ok, []}

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

  defp config, do: Application.get_env(:beamdash, __MODULE__, [])

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

  # Status codes from TypeSafe's API reference (Kev's server follows it,
  # and refuses a state over its model's length with a 422); bodies are
  # never shown.
  defp http_error(:kev, 401), do: "Kev rejected the API key. Check KEV_API_KEY."

  defp http_error(:kev, 422),
    do: "Kev rejected the request (422): the measurements may be too long for this Kev model."

  defp http_error(:kev, 503), do: "Kev's server is stopping. Try again once it is back."
  defp http_error(:jev, 401), do: "Jev rejected the API key. Check TYPESAFE_API_KEY."
  defp http_error(b, 413), do: "The measurements were too large for #{name(b)}."
  defp http_error(b, 429), do: "#{name(b)} rate limit reached. Wait a moment and try again."
  defp http_error(b, 529), do: "#{name(b)} is overloaded. Try again shortly."

  defp http_error(b, code) when code >= 500,
    do: "#{name(b)} is temporarily unavailable. Try again later."

  defp http_error(:jev, code) when code in [400, 422],
    do: "Jev rejected the request (#{code}). Check TYPESAFE_MODEL."

  defp http_error(b, code), do: "#{name(b)} rejected the request (#{code})."
end
