defmodule Beamdash.AIModels do
  @moduledoc "Lists models available to the configured provider credential."

  @providers %{
    "openai" => {"OPENAI_API_KEY", "https://api.openai.com/v1/models"},
    "anthropic" => {"ANTHROPIC_API_KEY", "https://api.anthropic.com/v1/models?limit=1000"},
    "gemini" =>
      {"GEMINI_API_KEY", "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"}
  }

  def list(provider, opts \\ []) do
    case @providers[provider] do
      nil ->
        {:error, "Choose an AI provider first."}

      {env, url} ->
        case Keyword.get(opts, :api_key, System.get_env(env)) do
          key when is_binary(key) and key != "" ->
            request = Keyword.get(opts, :request, &:httpc.request/4)
            fetch(provider, url, {:api_key, key}, request, [], 0)

          _ when provider == "gemini" ->
            with {:ok, token, project} <-
                   Keyword.get(opts, :google_credentials, &google_credentials/0).() do
              request = Keyword.get(opts, :request, &:httpc.request/4)
              fetch(provider, url, {:google_oauth, token, project}, request, [], 0)
            end

          _ ->
            {:error, "Set #{env} in the environment running beamdash."}
        end
    end
  end

  defp google_credentials do
    project = System.get_env("GOOGLE_CLOUD_PROJECT")
    executable = System.find_executable("gcloud")

    cond do
      is_nil(project) or String.trim(project) == "" ->
        {:error,
         "Set GOOGLE_CLOUD_PROJECT and sign in with Google application-default credentials."}

      is_nil(executable) ->
        {:error,
         "Install the Google Cloud CLI and sign in with Google application-default credentials."}

      true ->
        task =
          Task.async(fn ->
            System.cmd(executable, ["auth", "application-default", "print-access-token"],
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, 8_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {token, 0}} when byte_size(token) > 0 ->
            {:ok, String.trim(token), String.trim(project)}

          _ ->
            {:error,
             "Google account credentials are unavailable. Sign in with gcloud application-default login."}
        end
    end
  end

  defp fetch(_, _, _, _, _, 20), do: {:error, "The provider returned too many pages of models."}

  defp fetch(provider, url, credentials, request, found, page) do
    headers =
      case {provider, credentials} do
        {"openai", {:api_key, key}} ->
          [{~c"authorization", String.to_charlist("Bearer " <> key)}]

        {"anthropic", {:api_key, key}} ->
          [{~c"x-api-key", String.to_charlist(key)}, {~c"anthropic-version", ~c"2023-06-01"}]

        {"gemini", {:api_key, key}} ->
          [{~c"x-goog-api-key", String.to_charlist(key)}]

        {"gemini", {:google_oauth, token, project}} ->
          [
            {~c"authorization", String.to_charlist("Bearer " <> token)},
            {~c"x-goog-user-project", String.to_charlist(project)}
          ]
      end

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    with {:ok, {{_, 200, _}, _, body}} <-
           request.(
             :get,
             {String.to_charlist(url), headers},
             [timeout: 10_000, connect_timeout: 5_000, autoredirect: false, ssl: ssl],
             body_format: :binary
           ),
         {:ok, json} <- Jason.decode(body),
         {:ok, names, next} <- parse(provider, json) do
      names = found ++ names

      if next do
        separator = if String.contains?(url, "?"), do: "&", else: "?"
        param = if provider == "anthropic", do: "after_id", else: "pageToken"
        base = url |> String.split("&#{param}=", parts: 2) |> hd()

        fetch(
          provider,
          base <> separator <> param <> "=" <> URI.encode_www_form(next),
          credentials,
          request,
          names,
          page + 1
        )
      else
        {:ok, names |> Enum.uniq() |> Enum.sort()}
      end
    else
      {:ok, {{_, code, _}, _, _}} ->
        {:error,
         "Model list request failed (HTTP #{code}). Check the API key and account access."}

      _ ->
        {:error, "Could not retrieve models. Check the connection and API key."}
    end
  rescue
    _ -> {:error, "Could not retrieve models. Check the connection and API key."}
  end

  defp parse(provider, json) when provider in ["openai", "anthropic"] do
    case json do
      %{"data" => data} when is_list(data) ->
        names = for %{"id" => id} <- data, is_binary(id), byte_size(id) <= 256, do: id
        next = if provider == "anthropic" and json["has_more"] == true, do: json["last_id"]

        if json["has_more"] == true and provider == "anthropic" and not is_binary(next),
          do: {:error, :invalid_page},
          else: {:ok, names, next}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp parse("gemini", %{"models" => models} = json) when is_list(models) do
    names = for %{"name" => "models/" <> name} <- models, byte_size(name) <= 256, do: name
    next = json["nextPageToken"]
    if is_nil(next) or is_binary(next), do: {:ok, names, next}, else: {:error, :invalid_page}
  end

  defp parse(_, _), do: {:error, :invalid_response}
end
