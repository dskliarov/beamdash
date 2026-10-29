defmodule Beamdash.ModuleEditor do
  @moduledoc "Compiles Erlang modules and replaces a loaded module with a best-effort digest check."
  alias Beamdash.Target

  def compile(source) when is_binary(source) do
    with [_, name] <- Regex.run(~r/-module\s*\(\s*([a-z][a-zA-Z0-9_@]*)\s*\)\s*\./, source) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "beamdash-editor-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(dir)
      path = Path.join(dir, name <> ".erl")

      try do
        File.write!(path, source)

        case :compile.file(String.to_charlist(path), [
               :binary,
               :return_errors,
               :return_warnings,
               :debug_info
             ]) do
          {:ok, mod, beam, warnings} -> {:ok, mod, beam, warnings}
          {:error, errors, warnings} -> {:error, {errors, warnings}}
          other -> {:error, other}
        end
      after
        File.rm_rf(dir)
      end
    else
      _ -> {:error, "Expected an Erlang -module(name). declaration."}
    end
  end

  @doc "Compiles Elixir in a separate VM, optionally using an existing Mix project."
  def compile_elixir(source, mod, opts \\ []) when is_binary(source) and is_atom(mod) do
    project = Keyword.get(opts, :project)
    node = Keyword.get(opts, :node)

    with {:ok, versions} <- compiler_versions(node),
         {:ok, executable, args, cwd} <- compiler_command(project) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "beamdash-elixir-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(dir)
      input = Path.join(dir, "source.ex")
      output = Path.join(dir, "output.beam")
      script = Path.join(dir, "compile.exs")

      try do
        File.write!(input, source)
        File.write!(script, worker_script())

        arguments =
          args ++ [script, input, output, Atom.to_string(mod), versions.otp, versions.elixir]

        case run_compiler(executable, arguments, cwd) do
          {:ok, log} ->
            case File.read(output) do
              {:ok, beam} -> {:ok, mod, beam, log}
              {:error, reason} -> {:error, "Compiler produced no BEAM: #{inspect(reason)}"}
            end

          {:error, log} ->
            {:error, log}
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp compiler_versions(nil),
    do: {:ok, %{otp: List.to_string(:erlang.system_info(:otp_release)), elixir: System.version()}}

  defp compiler_versions(node) do
    with {:ok, otp} when is_list(otp) <- Target.rpc(node, :erlang, :system_info, [:otp_release]),
         {:ok, version} when is_binary(version) <- Target.rpc(node, System, :version, []) do
      {:ok, %{otp: List.to_string(otp), elixir: version}}
    else
      _ -> {:error, "Cannot determine the target's OTP and Elixir versions."}
    end
  end

  defp compiler_command(project) when project in [nil, ""] do
    case System.find_executable("elixir") do
      nil -> {:error, "Elixir executable was not found."}
      executable -> {:ok, executable, [], File.cwd!()}
    end
  end

  defp compiler_command(project) do
    cond do
      not File.regular?(Path.join(project, "mix.exs")) ->
        {:error, "The local project must contain mix.exs."}

      executable = System.find_executable("mix") ->
        {:ok, executable, ["run", "--no-start", "--no-compile", "--no-deps-check"],
         Path.expand(project)}

      true ->
        {:error, "Mix executable was not found."}
    end
  end

  defp worker_script do
    ~S"""
    [input, output, expected, otp, elixir] = System.argv()
    if List.to_string(:erlang.system_info(:otp_release)) != otp or System.version() != elixir do
      IO.puts(:stderr, "Compiler versions do not match the target (OTP #{otp}, Elixir #{elixir}).")
      System.halt(1)
    end
    try do
      modules = Code.compile_string(File.read!(input), input)
      case modules do
        [{mod, beam}] ->
          if Atom.to_string(mod) == expected do
            File.write!(output, beam)
          else
            IO.puts(:stderr, "Compiled module #{mod} does not match #{expected}.")
            System.halt(1)
          end
        _ ->
          IO.puts(:stderr, "Expected exactly one module (#{expected}); got #{inspect(Enum.map(modules, &elem(&1, 0)))}.")
          System.halt(1)
      end
    rescue
      e ->
        IO.puts(:stderr, Exception.format(:error, e, __STACKTRACE__))
        System.halt(1)
    end
    """
  end

  defp run_compiler(executable, args, cwd) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: args,
        cd: cwd,
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    collect_compiler(port, "", System.monotonic_time(:millisecond) + 30_000)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp collect_compiler(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_compiler(port, String.slice(output <> data, 0, 64_000), deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, status}} ->
        {:error, "Compiler exited with status #{status}:\n#{output}"}
    after
      remaining ->
        Port.close(port)
        {:error, "Compiler timed out after 30 seconds."}
    end
  end

  @doc "Runs a function from a staged BEAM in a separate local VM."
  def test_candidate(mod, beam, function, args, opts \\ [])
      when is_atom(mod) and is_binary(beam) and is_binary(function) and is_binary(args) do
    with {:ok, {^mod, _}} <- :beam_lib.md5(beam),
         {:ok, executable, command_args, cwd} <- compiler_command(Keyword.get(opts, :project)) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "beamdash-test-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(dir)

      try do
        beam_path = Path.join(dir, "candidate.beam")
        args_path = Path.join(dir, "args.txt")
        result_path = Path.join(dir, "result.txt")
        script_path = Path.join(dir, "test.exs")
        File.write!(beam_path, beam)
        File.write!(args_path, args)
        File.write!(script_path, candidate_test_script())

        arguments =
          command_args ++
            [script_path, beam_path, args_path, result_path, Atom.to_string(mod), function]

        case run_compiler(executable, arguments, cwd) do
          {:ok, log} ->
            case File.read(result_path) do
              {:ok, result} -> {:ok, result, log}
              {:error, reason} -> {:error, "Test produced no result: #{inspect(reason)}"}
            end

          {:error, error} ->
            {:error, error}
        end
      after
        File.rm_rf(dir)
      end
    else
      {:ok, _} -> {:error, "The staged BEAM does not match the selected module."}
      {:error, error} -> {:error, inspect(error)}
    end
  end

  defp candidate_test_script do
    ~S"""
    [beam_path, args_path, result_path, module_name, function] = System.argv()
    try do
      module = String.to_atom(module_name)
      {:module, ^module} = :code.load_binary(module, String.to_charlist(beam_path), File.read!(beam_path))
      {:ok, tokens, _} = :erl_scan.string(String.to_charlist(File.read!(args_path) <> "."))
      {:ok, args} = :erl_parse.parse_term(tokens)
      unless is_list(args), do: raise("Arguments must be an Erlang list")
      {fun, _} = Enum.find(module.module_info(:exports), fn {name, arity} ->
        Atom.to_string(name) == function and arity == length(args)
      end) || raise("No exported function matches the name and argument count")
      result = apply(module, fun, args)
      File.write!(result_path, inspect(result, limit: 100, printable_limit: 2000))
    catch
      kind, reason ->
        IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
        System.halt(1)
    end
    """
  end

  def backup(node, mod) do
    with {:ok, {^mod, beam, path}} <- Target.rpc(node, :code, :get_object_code, [mod]),
         {:ok, {^mod, digest}} <- :beam_lib.md5(beam),
         {:ok, ^digest} <- Target.rpc(node, mod, :module_info, [:md5]) do
      {:ok, %{beam: beam, path: path, digest: digest}}
    else
      _ ->
        {:error,
         "The server's BEAM file is unavailable or differs from the running module; rollback cannot be guaranteed."}
    end
  end

  def load(node, mod, beam, expected_digest) do
    # This check and load are separate RPCs. Callers must coordinate with
    # other code loaders; the code server does not provide a compare-and-load.
    with {:ok, ^expected_digest} <- Target.rpc(node, mod, :module_info, [:md5]),
         {:ok, {^mod, digest}} <- :beam_lib.md5(beam),
         {:ok, {:module, ^mod}} <-
           Target.rpc(node, :code, :load_binary, [mod, ~c"beamdash", beam]) do
      {:ok, digest}
    else
      other -> {:error, "Module changed or could not be loaded: #{inspect(other)}"}
    end
  end

  def test_call(node, mod, function, args) do
    with {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(args <> ".")),
         {:ok, values} when is_list(values) <- :erl_parse.parse_term(tokens),
         {:ok, exports} <- Target.rpc(node, mod, :module_info, [:exports]),
         {fun, _} <-
           Enum.find(exports, fn {f, arity} ->
             Atom.to_string(f) == function and arity == length(values)
           end),
         {:ok, result} <- Target.rpc(node, mod, fun, values) do
      {:ok, result}
    else
      other -> {:error, other}
    end
  end
end
