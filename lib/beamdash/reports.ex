defmodule Beamdash.Reports do
  @moduledoc """
  Reports an AI agent publishes after running the erlang-triage skill.

  Each client has its own token. The token is returned once, when the client
  is created; Settings keeps only its SHA-256 hash. A report is stored as one
  `ai_analyses` row about the attached node and does not depend on snapshot
  collection. A client that sends the same `run_id` again within a day gets
  the first row back instead of a second one.
  """

  alias Beamdash.{Settings, Store}

  @verdicts ~w(healthy needs_attention critical)
  @severities ~w(high medium low)
  @types ~w(bottleneck error caveat)
  @subject ~r/\A(triage|app:[A-Za-z0-9_.]{1,100})\z/
  @max_list 50
  @max_text 2_000
  @max_line 300
  @max_title 200
  @max_name 100
  @max_run_id 100
  @dedupe_ms 24 * 60 * 60 * 1000

  @doc "The clients, without their token hashes."
  def clients do
    for client <- Settings.report_clients(), do: Map.take(client, ~w(id name created_at))
  end

  @doc "Adds a client called `name` and returns its token, which is not saved anywhere else."
  def create_client(name) do
    name = String.trim(name)

    if name == "" or byte_size(name) > @max_name do
      {:error, "Give the client a name of up to #{@max_name} bytes."}
    else
      token = "bdr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      client = %{
        "id" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        "name" => name,
        "hash" => hash(token),
        "created_at" => System.system_time(:millisecond)
      }

      :ok = Settings.put_report_clients(Settings.report_clients() ++ [client])
      {:ok, token}
    end
  end

  @doc "Removes the client `id`; its token stops working at once."
  def revoke_client(id) when is_binary(id) do
    Settings.put_report_clients(Enum.reject(Settings.report_clients(), &(&1["id"] == id)))
  end

  @doc "The client whose token is `token`, or `:error`."
  def authenticate(token) when is_binary(token) do
    digest = hash(token)

    Enum.find_value(Settings.report_clients(), :error, fn client ->
      if is_binary(client["hash"]) and :crypto.hash_equals(client["hash"], digest),
        do: {:ok, client}
    end)
  end

  def authenticate(_token), do: :error

  @doc """
  Stores `params` as a report that `client` made about `node`. Returns
  `{:ok, run_id, :stored}`, `{:ok, run_id, :existing}` for a repeat, or
  `{:error, :store_down}` or `{:error, message}`.
  """
  def publish(client, params, node) do
    with {:ok, report} <- validate(params) do
      cond do
        Process.whereis(Store) == nil -> {:error, :store_down}
        existing?(client, report["run_id"]) -> {:ok, report["run_id"], :existing}
        true -> store(client, report, node)
      end
    end
  end

  defp store(client, report, node) do
    row = %{
      at: System.system_time(:millisecond),
      node: to_string(node),
      subject: report["subject"],
      data: Map.merge(report, %{"client_id" => client["id"], "client" => client["name"]})
    }

    :ok = Store.record(:ai_analyses, [row])
    {:ok, report["run_id"], :stored}
  end

  defp existing?(client, run_id) do
    from = System.system_time(:millisecond) - @dedupe_ms

    :ai_analyses
    |> Store.query(from: from, limit: 1_000)
    |> Enum.any?(&(&1.data["client_id"] == client["id"] and &1.data["run_id"] == run_id))
  end

  defp validate(%{} = params) do
    with {:ok, run_id} <- text(params, "run_id", @max_run_id, true),
         {:ok, subject} <- subject(params["subject"]),
         {:ok, verdict} <- choice(params["verdict"], @verdicts, "verdict"),
         {:ok, summary} <- text(params, "summary", @max_text, false),
         {:ok, findings} <- findings(params["findings"]),
         {:ok, healthy} <- lines(params["healthy"], "healthy"),
         {:ok, not_checked} <- lines(params["not_checked"], "not_checked") do
      {:ok,
       %{
         "run_id" => run_id,
         "subject" => subject,
         "verdict" => verdict,
         "summary" => summary,
         "findings" => findings,
         "healthy" => healthy,
         "not_checked" => not_checked
       }}
    end
  end

  defp validate(_params), do: {:error, "the report must be a JSON object"}

  defp subject(value) do
    if is_binary(value) and Regex.match?(@subject, value),
      do: {:ok, value},
      else: {:error, "subject must be triage or app:<name>"}
  end

  defp choice(value, allowed, key) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "#{key} must be one of: #{Enum.join(allowed, ", ")}"}
  end

  defp text(params, key, max, required?) do
    case Map.get(params, key) do
      value when is_binary(value) and byte_size(value) <= max ->
        if value == "" and required?, do: missing(key), else: {:ok, value}

      nil ->
        if required?, do: missing(key), else: {:ok, nil}

      _ ->
        {:error, "#{key} must be text of at most #{max} bytes"}
    end
  end

  defp missing(key), do: {:error, "#{key} is required"}

  defp findings(nil), do: {:ok, []}

  defp findings(list) when is_list(list) and length(list) <= @max_list,
    do: all(list, &finding/1)

  defp findings(_list), do: {:error, "findings must be a list of at most #{@max_list} items"}

  defp finding(%{} = finding) do
    with {:ok, severity} <- choice(finding["severity"], @severities, "severity"),
         {:ok, type} <- choice(finding["type"], @types, "type"),
         {:ok, title} <- text(finding, "title", @max_title, true),
         {:ok, evidence} <- text(finding, "evidence", @max_text, true),
         {:ok, verdict} <- text(finding, "verdict", @max_text, true),
         {:ok, source} <- text(finding, "source", @max_line, false),
         {:ok, fix} <- text(finding, "fix", @max_text, false),
         {:ok, verify} <- text(finding, "verify", @max_text, false) do
      {:ok,
       %{
         "severity" => severity,
         "type" => type,
         "title" => title,
         "evidence" => evidence,
         "verdict" => verdict,
         "source" => source,
         "fix" => fix,
         "verify" => verify
       }}
    end
  end

  defp finding(_finding), do: {:error, "each finding must be an object"}

  defp lines(nil, _key), do: {:ok, []}

  defp lines(list, key) when is_list(list) and length(list) <= @max_list do
    all(list, fn
      line when is_binary(line) and byte_size(line) <= @max_line -> {:ok, line}
      _ -> {:error, "#{key} lines must be text of at most #{@max_line} bytes"}
    end)
  end

  defp lines(_list, key), do: {:error, "#{key} must be a list of at most #{@max_list} lines"}

  defp all(items, check) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case check.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
end
