defmodule Beamdash.Insights.Model do
  @moduledoc """
  beamdash's own suggestion model: a multinomial logistic regression per
  question (process, GC, node memory, seq trace pattern, triage), trained
  offline by `mix beamdash.nx_train` (`Beamdash.Insights.Training`) and
  run here with Nx. It is the `:nx` backend of `Beamdash.Jev`: it answers
  the same questions with the same choices, instantly and without sending
  anything anywhere. It cannot answer "Ask beamdash" (free text).

  An advisor's state (nested maps of numbers and atoms, as sent to Jev)
  becomes a vector (`vector/2`): every number, on a signed log scale and
  standardized, with a flag for when it is missing, and every atom as a
  one-hot `path=value`. Lists (the raw series) are left out: the derived
  facts already describe them.

  The weights are in `priv/nx/models.etf`.
  """
  alias Beamdash.{GCAdvisor, MemoryAdvisor, ProcessAdvisor, SeqAdvisor}
  alias Beamdash.Insights.Series

  @key {__MODULE__, :models}

  @doc "The file holding the trained models."
  def path, do: Application.app_dir(:beamdash, "priv/nx/models.etf")

  @doc "The trained models, `%{version, trained_at, kinds: %{kind => model}}`, or nil."
  def models do
    case :persistent_term.get(@key, :unset) do
      :unset ->
        models = read()
        :persistent_term.put(@key, models)
        models

      models ->
        models
    end
  end

  @doc false
  # Uses `models` instead of the file (tests, or right after training).
  def put_models(models), do: :persistent_term.put(@key, models)

  defp read do
    # the file's keys are atoms Training defines; :safe decoding only
    # accepts atoms that already exist
    Code.ensure_loaded(Beamdash.Insights.Training)

    with {:ok, bin} <- File.read(path()),
         %{kinds: %{}} = models <- :erlang.binary_to_term(bin, [:safe]) do
      models
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def available?, do: models() != nil

  @doc "The model name shown with its answers."
  def name do
    case models() do
      %{version: v} -> "beamdash-nx-#{v}"
      _ -> "beamdash-nx"
    end
  end

  ## Features

  @doc """
  The leaves of `state` as `[{path, value}]`: numbers as they are, atoms,
  booleans and strings as `{:cat, value}`, nil as `nil`. Lists are skipped.
  """
  def leaves(state, prefix \\ "")

  def leaves(%{} = map, prefix) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.flat_map(fn {k, v} -> leaves(v, prefix <> to_string(k) <> ".") end)
  end

  def leaves(list, _prefix) when is_list(list), do: []
  def leaves(n, prefix) when is_number(n), do: [{trim(prefix), n}]
  def leaves(nil, prefix), do: [{trim(prefix), nil}]
  def leaves(v, prefix), do: [{trim(prefix), {:cat, to_string(v)}}]

  defp trim(prefix), do: String.trim_trailing(prefix, ".")

  @doc """
  The vocabulary of a set of states: `%{numeric: [path], categorical:
  ["path=value"]}`, sorted.
  """
  def vocabulary(states) do
    all = Enum.flat_map(states, &leaves/1)

    %{
      numeric: for({path, v} <- all, is_number(v), uniq: true, do: path) |> Enum.sort(),
      categorical: for({path, {:cat, v}} <- all, uniq: true, do: path <> "=" <> v) |> Enum.sort()
    }
  end

  @doc """
  `state` as a list of floats in `vocab`'s order: the numbers (signed
  log), then a missing flag per number, then the one-hot categories.
  Unknown paths and values are ignored.
  """
  def vector(state, vocab) do
    leaves = Map.new(leaves(state))

    numbers =
      Enum.map(vocab.numeric, fn path ->
        case leaves[path] do
          n when is_number(n) -> Series.slog(n)
          _ -> 0.0
        end
      end)

    missing = Enum.map(vocab.numeric, &if(is_number(leaves[&1]), do: 0.0, else: 1.0))

    cats =
      MapSet.new(for {path, {:cat, v}} <- leaves, do: path <> "=" <> v)

    numbers ++ missing ++ Enum.map(vocab.categorical, &if(&1 in cats, do: 1.0, else: 0.0))
  end

  ## Answers

  @doc """
  The probabilities of `model`'s classes for `state`: `%{class => p}`.
  """
  def predict(model, state) do
    x = state |> vector(model.vocabulary) |> Nx.tensor(type: :f32)
    mean = Nx.tensor(model.mean, type: :f32)
    sd = Nx.tensor(model.sd, type: :f32)
    x = x |> Nx.subtract(mean) |> Nx.divide(sd)

    logits =
      x
      |> Nx.dot(Nx.tensor(model.coefficients, type: :f32))
      |> Nx.add(Nx.tensor(model.bias, type: :f32))

    exp = Nx.exp(Nx.subtract(logits, Nx.reduce_max(logits)))
    probs = exp |> Nx.divide(Nx.sum(exp)) |> Nx.to_flat_list()

    model.classes |> Enum.zip(probs) |> Map.new()
  end

  @doc """
  Answers `questions` (`%{id => {instructions, choices}}`, as asked of
  Jev) about `state`, in the shape of Jev's response:
  `{:ok, %{"model" => name, "answers" => %{id => answer}}}`. A choice the
  model was not trained on gets probability 0.
  """
  def answer(state, questions) do
    case models() do
      nil ->
        {:error, "The local Nx model is not trained. Run mix beamdash.nx_train."}

      %{kinds: kinds} ->
        Enum.reduce_while(questions, {:ok, %{}}, fn {id, {_instructions, choices}}, {:ok, acc} ->
          with {kind, input} <- kind_for(state, id, choices),
               %{} = model <- kinds[kind] do
            {:cont, {:ok, Map.put(acc, id, choice_answer(predict(model, input), choices))}}
          else
            _ ->
              {:halt,
               {:error,
                "The local Nx model only answers the panels' own questions; Ask needs Jev or Kev."}}
          end
        end)
        |> case do
          {:ok, answers} -> {:ok, %{"model" => name(), "answers" => answers}}
          error -> error
        end
    end
  end

  @doc """
  Which model answers a question, from its choices (each advisor has its
  own): `{kind, input_state}`, or `:unsupported`. A triage question is a
  process question about one process of the table.
  """
  def kind_for(state, id, choices) do
    keys = choices |> Map.keys() |> MapSet.new()

    cond do
      keys == keys_of(ProcessAdvisor) and is_map(state[:processes]) and
          is_map_key(state.processes, id) ->
        row = Map.put(state.processes[id], :observed_window_s, state[:observed_window_s])
        {:triage, row}

      keys == keys_of(ProcessAdvisor) ->
        {:process, state}

      keys == keys_of(GCAdvisor) ->
        {:gc, state}

      keys == keys_of(MemoryAdvisor) ->
        {:memory, state}

      keys == keys_of(SeqAdvisor) ->
        {:seq, state}

      true ->
        :unsupported
    end
  end

  defp keys_of(advisor), do: advisor.choices() |> Map.keys() |> MapSet.new()

  # all of the question's choices, rounded so they still sum to 1
  defp choice_answer(probs, choices) do
    keys = choices |> Map.keys() |> Enum.sort()
    raw = Map.new(keys, &{&1, Map.get(probs, &1, 0.0)})
    total = raw |> Map.values() |> Enum.sum() |> max(1.0e-9)
    probabilities = Map.new(raw, fn {k, p} -> {k, Float.round(p / total, 4)} end)
    {choice, top} = Enum.max_by(probabilities, &elem(&1, 1))
    k = length(keys)

    %{
      "type" => "choice",
      "choice" => choice,
      # as TypeSafe defines it: 0 for a uniform answer, 1 for certainty
      "confidence" =>
        if(k > 1, do: Float.round(max(top - 1 / k, 0.0) / (1 - 1 / k), 4), else: 1.0),
      "probabilities" => probabilities
    }
  end
end
