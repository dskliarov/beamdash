defmodule Beamdash.AIModelsTest do
  use ExUnit.Case, async: true
  alias Beamdash.AIModels

  test "fetches authenticated model lists and follows Gemini pagination" do
    parent = self()

    request = fn :get, {url, headers}, options, _ ->
      send(parent, {:request, to_string(url), headers, options})

      body =
        if String.contains?(to_string(url), "pageToken=next"),
          do: ~s({"models":[{"name":"models/gemini-b"}]}),
          else: ~s({"models":[{"name":"models/gemini-a"}],"nextPageToken":"next"})

      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}}
    end

    assert {:ok, ["gemini-a", "gemini-b"]} =
             AIModels.list("gemini", api_key: "secret", request: request)

    assert_receive {:request, url, headers, options}
    assert url =~ "generativelanguage.googleapis.com"
    assert {~c"x-goog-api-key", ~c"secret"} in headers
    assert Keyword.get(options, :autoredirect) == false
    assert_receive {:request, next, _, _}
    assert next =~ "pageToken=next"
  end

  test "parses OpenAI and Claude models and does not leak provider error bodies" do
    for provider <- ["openai", "anthropic"] do
      request = fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"data":[{"id":"model-z"},{"id":"model-a"}]})}}
      end

      assert {:ok, ["model-a", "model-z"]} =
               AIModels.list(provider, api_key: "secret", request: request)
    end

    request = fn :get, _, _, _ -> {:ok, {{~c"HTTP/1.1", 401, ~c"Error"}, [], "secret"}} end
    assert {:error, error} = AIModels.list("openai", api_key: "secret", request: request)
    assert error =~ "401"
    refute error =~ "secret"
    assert {:error, error} = AIModels.list("openai", api_key: "")
    assert error =~ "OPENAI_API_KEY"
  end

  test "uses Google account credentials if a Gemini API key is absent" do
    parent = self()

    request = fn :get, {_, headers}, _, _ ->
      send(parent, headers)
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"models":[{"name":"models/gemini-a"}]})}}
    end

    assert {:ok, ["gemini-a"]} =
             AIModels.list("gemini",
               api_key: "",
               request: request,
               google_credentials: fn -> {:ok, "oauth-token", "project-id"} end
             )

    assert_receive headers
    assert {~c"authorization", ~c"Bearer oauth-token"} in headers
    assert {~c"x-goog-user-project", ~c"project-id"} in headers
    refute Enum.any?(headers, fn {name, _} -> name == ~c"x-goog-api-key" end)
  end
end
