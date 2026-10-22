defmodule Beamdash.AskAdvisor do
  @moduledoc """
  "Ask beamdash": a question typed in plain words ("who is leaking
  binaries?", "trace demo_shop") is routed by Jev to one of beamdash's
  views: a fixed list of destinations, each a page with its filters. Jev
  only picks the destination. A module named in the question is found
  here, among the modules loaded on the node, and passed to the Tracing
  or Profile page.

  Only the typed question is sent (and whether it names a loaded module).
  """
  alias Beamdash.Jev

  @destinations [
    {"processes_by_memory", "Processes using the most memory", "/?sort=memory",
     "Which processes use the most memory, the biggest processes.",
     "Memory of the node as a whole, or binaries or ETS specifically."},
    {"processes_by_queue", "Processes with the longest message queues", "/?sort=mq",
     "Message queues, mailboxes, backlogs, processes that fall behind.",
     "Memory or CPU questions."},
    {"processes_by_cpu", "Busiest processes (reductions per second)", "/?sort=rate",
     "Which processes are busy, use CPU, do the most work right now.",
     "Profiling the functions of a module."},
    {"gen_servers", "gen_server processes", "/?q=gen_server",
     "List or find gen_servers, GenServers.", "Supervisors or state machines."},
    {"supervisors", "Supervisors", "/?q=supervisor",
     "Supervisors, supervision trees, restarts structure.", "Workers."},
    {"gen_statems", "gen_statem processes", "/?q=gen_statem",
     "State machines, gen_statem processes.", "gen_servers."},
    {"process_triage", "Triage: which processes are worth a look", "/?triage=1",
     "Something is wrong but it is unclear where; which processes look suspicious or unhealthy.",
     "A question about one specific kind of memory or a specific module."},
    {"memory_overview", "Node memory overview", "/memory",
     "How much memory the node uses, what it is made of, memory limits.",
     "Leaks of a specific kind (binaries, ETS)."},
    {"memory_health", "Memory health check", "/memory?check=1",
     "Is there a memory problem or leak on the node, which kind of memory grows.",
     "A specific kind already named (binaries, ETS)."},
    {"memory_binaries", "Binary memory and its holders", "/memory?tab=binary",
     "Binary memory, binary leaks, large binaries, refc binaries, who holds binaries.",
     "Heap memory of processes."},
    {"memory_ets", "ETS tables", "/memory?tab=ets", "ETS tables, their size, growth and owners.",
     "Process memory."},
    {"gc", "Garbage collection", "/gc",
     "Garbage collection, GC pauses, heap sizes, full sweeps, fullsweep_after.",
     "Overall node memory."},
    {"gc_old_heap", "Processes with the biggest old heap", "/gc?sort=old_heap_size",
     "Old heap, data that survives collections, long-lived heap data.", "Binaries."},
    {"trace", "Trace function calls", "/trace",
     "Trace or watch the calls of a module or function, their arguments and results, exceptions.",
     "Measuring time spent (profiling) or messages between processes."},
    {"seq_trace", "Seq trace: messages between processes", "/seq",
     "Follow messages between processes, sequence diagrams, who calls whom with messages.",
     "Function calls inside one process."},
    {"profile", "Profile functions (time, calls, memory)", "/profile",
     "Profile, where time is spent, slow functions, hot spots, allocations per function, call counts.",
     "Watching individual calls (tracing)."},
    {"crashes", "Crash reports", "/crashes",
     "Crashes, errors, exceptions in processes, crash reports, processes dying.",
     "Exceptions of one traced function."},
    {"settings", "Settings", "/settings", "beamdash settings, turning Jev on or off.",
     "Anything about the node."},
    {"none", "Nothing here matches", nil,
     "The question is not about an Erlang/Elixir node or none of the views fit.",
     "Any question one of the views answers."}
  ]

  @choices Map.new(@destinations, fn {key, label, _path, what, not_for} ->
             {key, %{label: label, what: what, not_for: not_for}}
           end)
  @paths Map.new(@destinations, fn {key, _label, path, _w, _n} -> {key, path} end)

  @question %{
    question:
      "Which beamdash view best answers this question about a running Erlang/Elixir node?",
    rules: [
      "Pick the most specific view that answers the question.",
      "Choose none when no view fits."
    ]
  }

  def choices, do: @choices

  @doc """
  The page for a destination, with the module named in the question for
  Tracing and Profile. nil for "none".
  """
  def path(key, module \\ nil)
  def path("trace", mod) when is_atom(mod) and not is_nil(mod), do: "/trace?mod=#{mod}"
  def path("profile", mod) when is_atom(mod) and not is_nil(mod), do: "/profile?mod=#{mod}"
  def path(key, _mod), do: @paths[key]

  @doc """
  A loaded module named in `text`, in Erlang (`demo_shop`) or Elixir
  (`MyApp.Repo`) spelling, the longest match first; nil if none.
  """
  def module_in(text, modules) do
    words =
      ~r/[A-Za-z_][A-Za-z0-9_.@]*/
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.map(&(&1 |> String.trim_trailing(".") |> String.downcase()))
      # "MyApp.Repo.get" also names MyApp.Repo
      |> Enum.flat_map(&prefixes/1)
      |> MapSet.new()

    modules
    |> Enum.filter(fn mod ->
      erl = mod |> Atom.to_string() |> String.downcase()
      ex = erl |> String.replace_prefix("elixir.", "")
      MapSet.member?(words, erl) or MapSet.member?(words, ex)
    end)
    |> Enum.max_by(&byte_size(Atom.to_string(&1)), fn -> nil end)
  end

  @doc """
  Routes `text`. Returns `{:ok, %{go: path | nil, options: [%{label, path,
  probability}], model}}`: `go` is set when the top destination is clear
  (no close runner-up, not "none"); `options` are the likely ones.
  """
  def ask(text, module, opts \\ []) do
    state = %{question: String.slice(text, 0, 300), names_a_loaded_module: module != nil}

    with {:ok, a} <- Jev.ask(state, @question, @choices, opts) do
      options =
        a.ranking
        |> Enum.reject(&(&1.key == "none"))
        |> Enum.take(3)
        |> Enum.filter(&(&1.probability >= 0.05))
        |> Enum.map(
          &%{
            label: label(&1.key, module),
            path: path(&1.key, module),
            probability: &1.probability,
            key: &1.key
          }
        )

      go = if a.choice != "none" and a.alternative == nil, do: path(a.choice, module)
      {:ok, %{go: go, choice: a.choice, options: options, model: a.model}}
    end
  end

  defp prefixes(word) do
    parts = String.split(word, ".")
    for n <- length(parts)..1//-1, do: parts |> Enum.take(n) |> Enum.join(".")
  end

  defp label("trace", mod) when not is_nil(mod), do: "Trace calls into #{inspect_mod(mod)}"
  defp label("profile", mod) when not is_nil(mod), do: "Profile #{inspect_mod(mod)}"
  defp label(key, _mod), do: @choices[key].label

  defp inspect_mod(mod), do: Beamdash.Format.name(mod, :erlang)
end
