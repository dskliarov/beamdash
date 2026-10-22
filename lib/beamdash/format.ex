defmodule Beamdash.Format do
  @moduledoc """
  Display helpers. Everything that shows code takes a syntax, `:erlang` or
  `:elixir` (the UI toggle):

  | | `:erlang` | `:elixir` |
  |---|---|---|
  | function | `gen_server:loop/7`, `'Elixir.Foo':bar/1` | `:gen_server.loop/7`, `Foo.bar/1` |
  | term | `{ok,[1,2]}`, `#cart{total = 3}` | `{:ok, [1, 2]}`, `#cart{total: 3}` |
  """

  alias Beamdash.Record

  @type syntax :: :erlang | :elixir

  ## Functions and names

  def mfa(mfa, syntax \\ :erlang)

  # every function of a module (a wildcard trace)
  def mfa({m, :_, :_}, :erlang) when is_atom(m), do: "#{erl_atom(m)}:_/_"
  def mfa({m, :_, :_}, :elixir) when is_atom(m), do: "#{ex_module(m)}._/_"

  def mfa({m, f, a}, syntax) when is_atom(m) and is_atom(f) and is_integer(a),
    do: "#{fun_ref(m, f, syntax)}/#{a}"

  def mfa({m, f, args}, syntax) when is_atom(m) and is_atom(f) and is_list(args),
    do: mfa({m, f, length(args)}, syntax)

  def mfa(nil, _syntax), do: ""
  def mfa(other, syntax), do: term(other, syntax)

  # `mod:fun` / `Mod.fun`, without arity or arguments.
  defp fun_ref(m, f, :erlang), do: "#{erl_atom(m)}:#{erl_atom(f)}"

  defp fun_ref(m, f, :elixir) do
    fun = f |> inspect() |> String.trim_leading(":")
    "#{ex_module(m)}.#{fun}"
  end

  defp erl_atom(atom), do: atom |> :io_lib.write_atom() |> IO.chardata_to_string()

  defp ex_module(m) do
    case Atom.to_string(m) do
      "Elixir." <> mod -> mod
      _ -> inspect(m)
    end
  end

  @doc "A name for display (registered names, module lists): never quoted."
  def name(atom, syntax \\ :erlang)
  def name(nil, _syntax), do: nil

  def name(atom, :elixir) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> mod -> mod
      other -> other
    end
  end

  def name(atom, :erlang) when is_atom(atom), do: Atom.to_string(atom)

  @doc "Registered name if there is one, otherwise the initial call."
  def label(%{registered_name: reg, initial_call: ic}, syntax \\ :erlang),
    do: name(reg, syntax) || mfa(ic, syntax)

  def pid(pid, syntax \\ :erlang)
  def pid(pid, :erlang) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  def pid(pid, :elixir) when is_pid(pid), do: inspect(pid)
  def pid(pid, _syntax) when is_binary(pid), do: pid

  ## Terms

  @doc "One-line rendering of a term, cut at `max` characters."
  def term(term, syntax \\ :erlang, max \\ 160) do
    text =
      case syntax do
        :elixir -> inspect(term, limit: 20, printable_limit: 100, width: :infinity)
        :erlang -> erlang_text(term, line_length: 100_000, depth: 20, chars_limit: max * 2)
      end

    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  @doc "Full, pretty-printed rendering of a term."
  def pretty(term, syntax \\ :erlang)

  def pretty(term, :elixir),
    do: inspect(term, pretty: true, limit: :infinity, printable_limit: 4096, width: 100)

  def pretty(term, :erlang), do: erlang_text(term, line_length: 100, depth: -1)

  # io_lib_pretty with record names and field names, as the Erlang shell
  # prints them. Records recovered by erlyberly become tuples again and
  # their field names are fed back through record_print_fun.
  defp erlang_text(term, opts) do
    {plain, defs} = Record.to_erlang(term)

    record_fun = fn tag, n ->
      case defs do
        %{{^tag, ^n} => fields} -> fields
        _ -> :no
      end
    end

    options =
      [
        column: 1,
        line_length: Keyword.fetch!(opts, :line_length),
        depth: Keyword.fetch!(opts, :depth),
        record_print_fun: record_fun,
        encoding: :unicode
      ] ++ if(opts[:chars_limit], do: [chars_limit: opts[:chars_limit]], else: [])

    plain |> :io_lib_pretty.print(options) |> IO.chardata_to_string()
  end

  ## Traces

  @doc "A traced call: `mod:fun(Arg, ...)` or `Mod.fun(arg, ...)`."
  def call(entry, syntax \\ :erlang)

  def call(%{mod: mod, fun: fun, args: args}, syntax) when is_list(args) and is_atom(mod) do
    fun_ref(mod, fun, syntax) <> "(" <> Enum.map_join(args, ", ", &term(&1, syntax, 60)) <> ")"
  end

  def call(%{mod: mod, fun: fun, arity: arity}, syntax), do: mfa({mod, fun, arity}, syntax)

  def result(result, syntax \\ :erlang)
  def result(:pending, _syntax), do: "…"
  def result({:return, value}, syntax), do: term(value, syntax)
  def result({:exception, {class, reason}}, :erlang), do: "#{class}:#{term(reason, :erlang)}"
  def result({:exception, {class, reason}}, :elixir), do: "#{class}: #{term(reason, :elixir)}"

  @doc "Wall-clock time (UTC) of a microsecond timestamp, `HH:MM:SS.mmm`."
  def time(nil), do: ""

  def time(us) when is_integer(us) do
    us
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_time()
    |> Time.truncate(:millisecond)
    |> Time.to_string()
  end

  def duration(%{call_us: c, return_us: r}) when is_integer(c) and is_integer(r) do
    case r - c do
      us when us < 1_000 -> "#{us} µs"
      us when us < 1_000_000 -> "#{Float.round(us / 1_000, 1)} ms"
      us -> "#{Float.round(us / 1_000_000, 2)} s"
    end
  end

  def duration(_), do: ""

  ## Numbers

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def number(other), do: to_string(other)

  def bytes(n) when is_integer(n) and n >= 1_073_741_824,
    do: "#{Float.round(n / 1_073_741_824, 1)} GB"

  def bytes(n) when is_integer(n) and n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  def bytes(n) when is_integer(n) and n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def bytes(n) when is_integer(n), do: "#{n} B"
  def bytes(other), do: to_string(other)

  ## Errors

  @doc "Human-readable message for errors from Target, Tracer and friends."
  def error(:not_connected), do: "Not connected."
  def error(:empty_node_name), do: "Enter a node name, e.g. foo@myhost."

  def error(:connect_failed),
    do:
      "Could not connect. Check the node name and cookie, and that both nodes use the same naming (-sname vs -name)."

  def error(:not_distributed), do: "This VM is not running distribution."

  def error({:distribution_failed, reason}),
    do:
      "Could not start distribution here (is epmd running? try `epmd -daemon`): #{inspect(reason)}"

  def error({:distribution_mode_locked, _reason}),
    do:
      "This target needs the other short/long name mode, but beamdash itself was started as a named node (-sname/-name), so it can't switch automatically. Restart beamdash without -sname/-name, or with the mode this target needs."

  def error({:agent_load_failed, reason}),
    do: "Connected, but could not load the agent into the target: #{inspect(reason)}"

  def error({:agent_not_found, mod}),
    do: "The #{mod} module is missing from this build. Run `mix compile`."

  def error({:trace_failed, reason}), do: "Could not start the trace: #{inspect(reason)}"

  def error({:wildcard_not_allowed, mod}),
    do:
      "Every function of #{mod} cannot be traced at once: the tracing itself runs in it. Trace single functions instead."

  def error({:functions_traced, mod}),
    do: "Some functions of #{mod} are traced already. Stop them first to trace all of them."

  def error({:module_traced, mod}),
    do: "Every function of #{mod} is traced already."

  def error({:error, {:erpc, :timeout}}), do: "The target did not answer in time."
  def error({:error, {:erpc, :noconnection}}), do: "Lost connection to the target."

  def error(:kubectl_not_found),
    do: "kubectl is not on PATH."

  def error({:kubeconfig_list_failed, reason}),
    do: "Could not list kubeconfig files under ~/.kube: #{inspect(reason)}"

  def error({:pod_list_failed, reason}),
    do: "Could not list pods in that namespace: #{inspect(reason)}"

  def error({:container_list_failed, reason}),
    do: "Could not list the pod's containers: #{inspect(reason)}"

  def error({:binary_list_failed, reason}),
    do: "Could not list /app/bin in the pod: #{inspect(reason)}"

  def error({:discovery_failed, reason}),
    do:
      "Could not read the node name and cookie from the pod (does this binary support `rpc`?): #{inspect(reason)}"

  def error({:port_forward_failed, reason}),
    do: "Could not open the kubectl port-forward: #{inspect(reason)}"

  def error({:epmd_discovery_failed, reason}),
    do: "Could not discover the node's distribution port via epmd: #{inspect(reason)}"

  def error(other), do: inspect(other)
end
