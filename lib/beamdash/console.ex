defmodule Beamdash.Console do
  @moduledoc "A per-page evaluator running on the connected node."
  alias Beamdash.{AgentLoader, Target}

  def start(node, owner, language) when language in [:erlang, :elixir] do
    with :ok <- AgentLoader.ensure_loaded(node, &Target.rpc/4, :beamdash_console),
         {:ok, {:ok, session}} <- Target.rpc(node, :beamdash_console, :start, [owner, language]) do
      {:ok, session}
    end
  end

  def eval(node, session, code, timeout \\ 5000)

  def eval(node, session, code, timeout)
      when is_binary(code) and byte_size(code) <= 32768 and is_integer(timeout) and timeout >= 100 and
             timeout <= 60000,
      do: Target.rpc(node, :beamdash_console, :eval, [session, code, timeout], timeout + 2000)

  def eval(_, _, _, _), do: {:error, :invalid_command_or_timeout}

  @doc "Submits REPL input, returning :incomplete when the parser needs another line."
  def submit(node, session, code, timeout \\ 5000)

  def submit(node, session, code, timeout)
      when is_binary(code) and byte_size(code) <= 32768 and is_integer(timeout) and timeout >= 100 and
             timeout <= 60000,
      do: Target.rpc(node, :beamdash_console, :submit, [session, code, timeout], timeout + 2000)

  def submit(_, _, _, _), do: {:error, :invalid_command_or_timeout}

  @doc "Completes loaded module names and exported functions without evaluating code."
  def complete(node, language, token)
      when language in [:erlang, :elixir] and is_binary(token) and byte_size(token) <= 256 do
    with {:ok, loaded} <- Target.rpc(node, :code, :all_loaded, [], 1000) do
      modules =
        loaded |> Enum.map(fn {mod, _} -> {module_name(mod, language), mod} end) |> Enum.sort()

      separator = if language == :elixir, do: ".", else: ":"

      names =
        for {name, _} <- modules,
            String.starts_with?(name, token),
            do: %{label: name, insert: name <> separator}

      functions =
        case Enum.find(Enum.sort_by(modules, fn {name, _} -> -byte_size(name) end), fn {name, _} ->
               String.starts_with?(token, name <> separator)
             end) do
          nil ->
            []

          {name, mod} ->
            prefix = name <> separator
            query = String.replace_prefix(token, prefix, "")

            case Target.rpc(node, mod, :module_info, [:exports], 1000) do
              {:ok, exports} ->
                for {fun, arity} <- Enum.sort(exports),
                    fun not in [:module_info, :__info__],
                    function = function_name(fun, language),
                    String.starts_with?(function, query),
                    do: %{
                      label: "#{prefix}#{function}/#{arity}",
                      insert: prefix <> function <> if(arity == 0, do: "()", else: "(")
                    }

              _ ->
                []
            end
        end

      (functions ++ names) |> Enum.uniq_by(& &1.label) |> Enum.take(30)
    else
      _ -> []
    end
  end

  def complete(_, _, _), do: []

  defp module_name(mod, :elixir) do
    case Atom.to_string(mod) do
      "Elixir." <> name -> name
      _ -> inspect(mod)
    end
  end

  defp module_name(mod, :erlang), do: mod |> :io_lib.write_atom() |> IO.chardata_to_string()
  defp function_name(fun, :elixir), do: Atom.to_string(fun)
  defp function_name(fun, :erlang), do: fun |> :io_lib.write_atom() |> IO.chardata_to_string()

  def stop(session) when is_pid(session), do: :erlang.send(session, :stop, [:noconnect])
  def stop(_), do: :ok
end
