defmodule ExberlyWeb.ProfileLive do
  @moduledoc """
  Profiling with OTP's tprof (`Exberly.Profiler`): choose what to
  measure, which functions and processes and for how long; the result is a
  sortable, filterable table of functions, in total or per process.

  Functions are picked as on the Tracing tab: a loaded module from a
  filterable list, then the whole module or single functions from its
  grid; picks show as chips. Patterns can also be typed (`lists:seq/2`,
  `_` for everything); both are profiled together.
  """
  use Phoenix.LiveView

  alias Exberly.{Format, Profiler, Target, Tracer}

  import ExberlyWeb.FunctionList,
    only: [matching_modules: 3, functions_of: 2, needle: 1, matches?: 3, fn_name: 2, highlight: 1]

  @types [
    call_time: {"Call time", "time spent in each function"},
    call_count: {"Call count", "how often each function is called"},
    call_memory: {"Memory", "heap allocated by each function"}
  ]
  @max_seconds 600

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket,
        status: status,
        node: node,
        available: nil,
        form: %{
          "type" => "call_time",
          "patterns" => "",
          "procs" => "all",
          "proc_list" => "",
          "seconds" => "10"
        },
        form_error: nil,
        # the picker: loaded modules, the module shown, searches, and what is picked
        modules: [],
        pick_q: "",
        pick_mod: nil,
        fq: "",
        ff: :all,
        picked: [],
        profile: %{status: :idle, result: nil, info: nil, error: nil, config: nil},
        view: "all",
        sort: {:measurement, :desc},
        filter: "",
        now: System.monotonic_time(:millisecond)
      )

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = Profiler.subscribe()
      :timer.send_interval(500, :tick)
      {:ok, socket |> assign(profile: Profiler.state()) |> check_available() |> load_modules()}
    else
      {:ok, socket}
    end
  end

  defp check_available(%{assigns: %{status: :connected}} = socket) do
    case Profiler.available() do
      {:ok, true} -> assign(socket, available: true)
      {:ok, {false, otp}} -> assign(socket, available: {:no, otp})
      {:error, reason} -> assign(socket, available: {:error, Format.error(reason)})
    end
  end

  defp check_available(socket), do: assign(socket, available: nil)

  defp load_modules(%{assigns: %{available: true}} = socket) do
    case Tracer.module_functions() do
      {:ok, mods} -> assign(socket, modules: mods)
      {:error, _} -> socket
    end
  end

  defp load_modules(socket), do: socket

  # ?mod= opens that module (a link from "Ask exberly")
  @impl true
  def handle_params(%{"mod" => mod}, _uri, socket) do
    case Enum.find(socket.assigns.modules, fn {m, _, _} -> Atom.to_string(m) == mod end) do
      {m, _, _} -> {:noreply, assign(socket, pick_mod: m, pick_q: mod)}
      nil -> {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  ## Events

  @impl true
  def handle_event("form", %{"profile" => params}, socket),
    do: {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params), form_error: nil)}

  ## the picker

  def handle_event("pick_search", params, socket),
    do:
      {:noreply,
       assign(socket,
         pick_q: Map.get(params, "pick_q", socket.assigns.pick_q),
         fq: Map.get(params, "fq", socket.assigns.fq)
       )}

  def handle_event("pick_module", %{"mod" => mod}, socket),
    do: {:noreply, assign(socket, pick_mod: String.to_existing_atom(mod), fq: "")}

  def handle_event("pick_ff", %{"f" => f}, socket) when f in ~w(all exported local picked),
    do: {:noreply, assign(socket, ff: String.to_existing_atom(f))}

  def handle_event("refresh_modules", _params, socket), do: {:noreply, load_modules(socket)}

  def handle_event("pick", %{"mod" => m, "fun" => f, "arity" => a}, socket) do
    pattern = parse_pick(m, f, a)

    {:noreply,
     assign(socket, picked: toggle_pick(socket.assigns.picked, pattern), form_error: nil)}
  end

  def handle_event("unpick_all", _params, socket), do: {:noreply, assign(socket, picked: [])}

  def handle_event("start", %{"profile" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    socket = assign(socket, form: form)

    with {:ok, patterns} <- patterns(socket.assigns.picked, form["patterns"]),
         {:ok, procs} <- parse_procs(form["procs"], form["proc_list"], socket.assigns.node),
         {:ok, seconds} <- parse_seconds(form["seconds"]),
         {:ok, _info} <-
           Profiler.start(%{
             type: String.to_existing_atom(form["type"]),
             patterns: patterns,
             processes: procs,
             seconds: seconds
           }) do
      {:noreply, assign(socket, form_error: nil, view: "all", filter: "")}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, form_error: message)}

      {:error, reason} ->
        {:noreply, assign(socket, form_error: "Could not start tprof: #{Format.error(reason)}")}
    end
  end

  def handle_event("stop", _params, socket) do
    :ok = Profiler.stop()
    {:noreply, socket}
  end

  def handle_event("snapshot", _params, socket) do
    :ok = Profiler.snapshot()
    {:noreply, socket}
  end

  def handle_event("view", %{"view" => view}, socket), do: {:noreply, assign(socket, view: view)}

  def handle_event("filter", %{"q" => q}, socket), do: {:noreply, assign(socket, filter: q)}

  def handle_event("sort", %{"col" => col}, socket)
      when col in ~w(function calls measurement per_call) do
    col = String.to_existing_atom(col)

    dir =
      case socket.assigns.sort do
        {^col, :desc} -> :asc
        {^col, :asc} -> :desc
        _ -> if col == :function, do: :asc, else: :desc
      end

    {:noreply, assign(socket, sort: {col, dir})}
  end

  ## Messages

  @impl true
  def handle_info({:exberly_profile, profile}, socket),
    do: {:noreply, assign(socket, profile: profile)}

  def handle_info(:tick, %{assigns: %{profile: %{status: :running}}} = socket),
    do: {:noreply, assign(socket, now: System.monotonic_time(:millisecond))}

  def handle_info(:tick, socket), do: {:noreply, socket}

  def handle_info({:exberly_target, {:connected, node}}, socket),
    do:
      {:noreply,
       socket
       |> assign(status: :connected, node: node, picked: [], pick_mod: nil)
       |> check_available()
       |> load_modules()}

  def handle_info({:exberly_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, available: nil)}

  ## Parsing

  # Picked patterns, then typed ones (either may be empty, not both).
  defp patterns(picked, text) do
    cond do
      String.trim(text || "") == "" and picked != [] ->
        {:ok, picked}

      picked == [] ->
        Profiler.parse_patterns(text || "")

      true ->
        with {:ok, typed} <- Profiler.parse_patterns(text), do: {:ok, Enum.uniq(picked ++ typed)}
    end
  end

  defp parse_pick(m, "_", "_"), do: {String.to_existing_atom(m), :_, :_}

  defp parse_pick(m, f, a),
    do: {String.to_existing_atom(m), String.to_existing_atom(f), String.to_integer(a)}

  @doc false
  # Adds or removes a pick. A whole module replaces its single functions;
  # a function of a module picked whole is already included.
  def toggle_pick(picked, pattern) do
    cond do
      pattern in picked ->
        List.delete(picked, pattern)

      match?({_, :_, :_}, pattern) ->
        {mod, _, _} = pattern
        Enum.reject(picked, &match?({^mod, _, _}, &1)) ++ [pattern]

      {elem(pattern, 0), :_, :_} in picked ->
        picked

      true ->
        picked ++ [pattern]
    end
  end

  defp parse_procs("all", _list, _node), do: {:ok, :all}
  defp parse_procs("new", _list, _node), do: {:ok, :new}
  defp parse_procs("existing", _list, _node), do: {:ok, :existing}

  defp parse_procs("list", list, node) do
    items = list |> String.split(~r/[\s,]+/, trim: true)

    if items == [] do
      {:error,
       "Enter the processes to profile: registered names or pids, e.g. demo_shop <0.85.0>."}
    else
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        cond do
          Regex.match?(~r/^<\d+\.\d+\.\d+>$/, item) ->
            # pids as the target prints them (<0.85.0>) or as shown here
            local = Target.localize_pid(item, node)
            {:cont, {:ok, acc ++ [:erlang.list_to_pid(String.to_charlist(local))]}}

          Regex.match?(~r/^[a-zA-Z][\w.@]*$/, item) ->
            {:cont, {:ok, acc ++ [String.to_atom(item)]}}

          true ->
            {:halt, {:error, "“#{item}” is not a registered name or a pid."}}
        end
      end)
    end
  end

  defp parse_seconds(text) do
    case Integer.parse(String.trim(text || "")) do
      {n, ""} when n >= 1 and n <= @max_seconds -> {:ok, n}
      _ -> {:error, "Profile for 1 to #{@max_seconds} seconds."}
    end
  end

  ## Rendering

  @impl true
  def render(assigns) do
    assigns = assign(assigns, table: table(assigns), types: @types)

    ~H"""
    <main class="wrap">
      <ExberlyWeb.Layouts.header
        active={:profile}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={ExberlyWeb.JevSection.show?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>

      <div :if={@status == :connected and match?({:no, _}, @available)} class="notice">
        Profiling uses tprof, which comes with OTP 27 and later; {@node} runs OTP {elem(
          @available,
          1
        )}.
      </div>
      <p :if={match?({:error, _}, @available)} class="error">{elem(@available, 1)}</p>

      <section :if={@status == :connected and @available == true} class="profile">
        <%!-- the picker's search boxes belong to this form (form="pick-form"),
             so typing in them, or Enter, never submits the profile --%>
        <form
          :if={@profile.status != :running}
          id="pick-form"
          phx-change="pick_search"
          phx-submit="pick_search"
        >
        </form>
        <form
          :if={@profile.status != :running}
          id="profile-form"
          class="profile-form"
          phx-change="form"
          phx-submit="start"
        >
          <fieldset class="measure">
            <legend>Measure</legend>
            <label
              :for={{value, {label, hint}} <- @types}
              class={["measure-opt", @form["type"] == to_string(value) && "active"]}
            >
              <input
                type="radio"
                name="profile[type]"
                value={value}
                checked={@form["type"] == to_string(value)}
              />
              <strong>{label}</strong> <span class="muted small">{hint}</span>
            </label>
          </fieldset>

          <div class="field">
            <span>Functions</span>
            <div class="picked" aria-live="polite">
              <span :if={@picked == []} class="muted small">
                Pick a module or functions below, or type patterns.
              </span>
              <span :for={{m, f, a} <- @picked} class="chip">
                {pick_text({m, f, a}, @syntax)}
                <a
                  href="#"
                  phx-click="pick"
                  phx-value-mod={m}
                  phx-value-fun={f}
                  phx-value-arity={a}
                  title="Remove"
                  aria-label={"Remove #{pick_text({m, f, a}, @syntax)}"}
                >
                  ×
                </a>
              </span>
              <button
                :if={length(@picked) > 1}
                type="button"
                class="secondary small-btn"
                phx-click="unpick_all"
              >
                Clear
              </button>
            </div>
            <.picker
              modules={@modules}
              shown_modules={matching_modules(@modules, @pick_q, @syntax)}
              pick_q={@pick_q}
              pick_mod={@pick_mod}
              fq={@fq}
              ff={@ff}
              picked={@picked}
              syntax={@syntax}
            />
          </div>

          <label class="field">
            <span class="muted small">Or type patterns</span>
            <input
              type="text"
              name="profile[patterns]"
              value={@form["patterns"]}
              placeholder="e.g. lists:seq/2, MyApp.Repo.get/2   (_ = everything)"
              autocomplete="off"
              spellcheck="false"
            />
            <span class="muted small">
              Modules or functions, comma separated: <code>mod</code>, <code>mod:fun</code>,
              <code>mod:fun/arity</code>
              or Elixir <code>Mod.fun/arity</code>. <code>_</code>
              matches anything; profiling every function slows the node down.
            </span>
          </label>

          <div class="field-row">
            <label class="field">
              <span>Processes</span>
              <select name="profile[procs]" disabled={@form["type"] == "call_count"}>
                <option value="all" selected={@form["procs"] == "all"}>All processes</option>
                <option value="existing" selected={@form["procs"] == "existing"}>
                  Existing processes
                </option>
                <option value="new" selected={@form["procs"] == "new"}>
                  New processes only
                </option>
                <option value="list" selected={@form["procs"] == "list"}>
                  Specific processes…
                </option>
              </select>
              <span :if={@form["type"] == "call_count"} class="muted small">
                Call count counts calls from every process.
              </span>
            </label>
            <label
              :if={@form["procs"] == "list" and @form["type"] != "call_count"}
              class="field grow"
            >
              <span>Names or pids</span>
              <input
                type="text"
                name="profile[proc_list]"
                value={@form["proc_list"]}
                placeholder="demo_shop <0.85.0>"
                autocomplete="off"
              />
              <span class="muted small">Processes they spawn are profiled too.</span>
            </label>
            <label class="field">
              <span>Duration</span>
              <span class="with-unit">
                <input
                  type="number"
                  name="profile[seconds]"
                  value={@form["seconds"]}
                  min="1"
                  max="600"
                  inputmode="numeric"
                /> s
              </span>
            </label>
          </div>

          <p :if={@form_error} class="error">{@form_error}</p>
          <div class="actions">
            <button type="submit">Start profiling</button>
          </div>
        </form>

        <div :if={@profile.status == :running} class="profile-running">
          <div class="run-head">
            <span class="live-dot" aria-hidden="true"></span>
            <strong>Profiling {type_label(@profile.config.type)}</strong>
            <span class="muted">
              {Enum.map_join(@profile.config.patterns, ", ", &pattern_text(&1, @syntax))} · {procs_text(
                @profile
              )}
            </span>
          </div>
          <div
            class="progress"
            role="progressbar"
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={progress(@profile, @now)}
          >
            <span style={"width: #{progress(@profile, @now)}%"}></span>
          </div>
          <div class="run-foot">
            <span class="muted small">
              {seconds_left(@profile, @now)} s left · {functions_text(@profile.info)}
            </span>
            <button class="secondary" phx-click="snapshot">Refresh results</button>
            <button phx-click="stop">Stop now</button>
          </div>
          <p :if={@profile.info.unmatched != []} class="notice small">
            No functions match {Enum.map_join(
              @profile.info.unmatched,
              ", ",
              &pattern_text(&1, @syntax)
            )} (is the module loaded?).
          </p>
        </div>

        <p :if={@profile.error} class="error">tprof: {Format.error(@profile.error)}</p>

        <div :if={@profile.result} class="profile-result">
          <div class="result-head">
            <h2>
              {type_label(@profile.result.type)} ·
              <span class="mono">{measure(
                @profile.result.type,
                view_total(@profile.result, @view),
                @profile.result.word_size
              )}</span>
            </h2>
            <span class="muted small">
              {Format.number(@profile.result.functions)} function{if @profile.result.functions != 1,
                do: "s"} measured
              · {if @profile.status == :running, do: "so far", else: "final"}, {Calendar.strftime(
                @profile.result.collected_at,
                "%H:%M:%S"
              )} UTC
            </span>
          </div>

          <div class="result-tools">
            <form :if={@profile.result.processes != []} phx-change="view" class="view-select">
              <label class="muted small">
                Show
                <select name="view">
                  <option value="all" selected={@view == "all"}>All processes</option>
                  <option
                    :for={p <- @profile.result.processes}
                    value={Format.pid(p.pid, :erlang)}
                    selected={@view == Format.pid(p.pid, :erlang)}
                  >
                    {proc_label(p, @syntax)} – {measure(
                      @profile.result.type,
                      p.total,
                      @profile.result.word_size
                    )}
                  </option>
                </select>
              </label>
            </form>
            <form phx-change="filter" phx-submit="filter" class="grow">
              <input
                type="search"
                name="q"
                value={@filter}
                placeholder="Filter functions"
                phx-debounce="150"
                autocomplete="off"
                aria-label="Filter functions"
              />
            </form>
            <span class="muted small">{Format.number(length(@table))} shown</span>
          </div>

          <table class="profile-table">
            <thead>
              <tr>
                <th class="sortable" phx-click="sort" phx-value-col="function">
                  Function{arrow(@sort, :function)}
                </th>
                <th class="num sortable" phx-click="sort" phx-value-col="calls">
                  Calls{arrow(@sort, :calls)}
                </th>
                <th class="num sortable" phx-click="sort" phx-value-col="measurement">
                  {measure_heading(@profile.result.type)}{arrow(@sort, :measurement)}
                </th>
                <th class="num sortable" phx-click="sort" phx-value-col="per_call">
                  Per call{arrow(@sort, :per_call)}
                </th>
                <th class="pct">Share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={l <- @table}>
                <td class="mono">{Format.mfa(l.mfa, @syntax)}</td>
                <td class="num">{Format.number(l.calls)}</td>
                <td class="num">
                  {measure(@profile.result.type, l.measurement, @profile.result.word_size)}
                </td>
                <td class="num">
                  {per_call(@profile.result.type, l.per_call, @profile.result.word_size)}
                </td>
                <td class="pct">
                  <div class="share">
                    <span class="share-bar">
                      <span style={"width: #{Float.round(l.percent * 1.0, 1)}%"}></span>
                    </span>
                    <span class="muted small">{Float.round(l.percent * 1.0, 1)}%</span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@table == []} class="muted">
            {if @filter != "",
              do: "No functions match the filter.",
              else: "Nothing measured yet: the traced functions were not called."}
          </p>
        </div>
      </section>
    </main>
    """
  end

  defp table(%{profile: %{result: nil}}), do: []

  defp table(%{
         profile: %{result: result},
         view: view,
         filter: filter,
         sort: sort,
         syntax: syntax
       }) do
    needle = filter |> String.trim() |> String.downcase()

    lines =
      case view do
        "all" ->
          result.lines

        pid_text ->
          case Enum.find(result.processes, &(Format.pid(&1.pid, :erlang) == pid_text)) do
            nil -> result.lines
            p -> p.lines
          end
      end

    lines
    |> Enum.filter(fn l ->
      needle == "" or String.contains?(String.downcase(Format.mfa(l.mfa, syntax)), needle)
    end)
    |> sort_lines(sort, syntax)
  end

  defp sort_lines(lines, {:function, dir}, syntax),
    do: Enum.sort_by(lines, &Format.mfa(&1.mfa, syntax), dir)

  defp sort_lines(lines, {col, dir}, _syntax), do: Enum.sort_by(lines, &Map.fetch!(&1, col), dir)

  defp view_total(result, "all"), do: result.total

  defp view_total(result, pid_text) do
    case Enum.find(result.processes, &(Format.pid(&1.pid, :erlang) == pid_text)) do
      nil -> result.total
      p -> p.total
    end
  end

  defp arrow({col, :asc}, col), do: " ▲"
  defp arrow({col, :desc}, col), do: " ▼"
  defp arrow(_sort, _col), do: ""

  defp type_label(type), do: @types |> Keyword.fetch!(type) |> elem(0)

  defp measure_heading(:call_count), do: "Count"
  defp measure_heading(:call_time), do: "Time"
  defp measure_heading(:call_memory), do: "Allocated"

  # call_count: calls; call_time: microseconds; call_memory: words
  defp measure(:call_count, n, _word), do: Format.number(n)
  defp measure(:call_time, us, _word), do: time_text(us)
  defp measure(:call_memory, words, word), do: Format.bytes(words * word)

  defp per_call(:call_count, _n, _word), do: "1"
  defp per_call(:call_time, us, _word), do: time_text(us)
  defp per_call(:call_memory, words, word), do: Format.bytes(round(words * word))

  defp time_text(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 2)} s"
  defp time_text(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 2)} ms"
  defp time_text(us) when is_float(us), do: "#{Float.round(us, 1)} µs"
  defp time_text(us), do: "#{us} µs"

  defp pattern_text({:_, :_, :_}, _syntax), do: "everything"
  defp pattern_text({m, :_, :_}, syntax), do: Format.name(m, syntax)
  defp pattern_text({m, f, :_}, syntax), do: "#{Format.name(m, syntax)}:#{f}"
  defp pattern_text({m, f, a}, syntax), do: Format.mfa({m, f, a}, syntax)

  defp procs_text(%{config: %{type: :call_count}}), do: "calls from every process"

  defp procs_text(%{config: %{processes: procs}, info: info}) do
    what =
      case procs do
        :all ->
          "all processes"

        :new ->
          "new processes"

        :existing ->
          "existing processes"

        list ->
          if length(list) == 1,
            do: "1 chosen process and what it spawns",
            else: "#{length(list)} chosen processes and what they spawn"
      end

    case info.traced do
      %{count: n} -> "#{what} (#{Format.number(n)} traced)"
      _ -> what
    end
  end

  defp functions_text(%{functions: :all}), do: "every function traced"

  defp functions_text(%{functions: n}),
    do: "#{Format.number(n)} function#{if n != 1, do: "s"} traced"

  defp proc_label(%{name: name, pid: pid}, syntax) when is_atom(name) and name not in [nil],
    do: "#{Format.name(name, syntax)} #{Format.pid(pid, syntax)}"

  defp proc_label(%{pid: pid}, syntax), do: Format.pid(pid, syntax)

  defp progress(%{started_at: t0, duration_ms: d}, now) when is_integer(t0) and d > 0,
    do: min(100, round((now - t0) * 100 / d))

  defp progress(_, _), do: 0

  defp seconds_left(%{started_at: t0, duration_ms: d}, now) when is_integer(t0),
    do: max(0, div(d - (now - t0) + 999, 1000))

  defp seconds_left(_, _), do: 0

  attr :modules, :list, required: true
  attr :shown_modules, :list, required: true
  attr :pick_q, :string, required: true
  attr :pick_mod, :atom, required: true
  attr :fq, :string, required: true
  attr :ff, :atom, required: true
  attr :picked, :list, required: true
  attr :syntax, :atom, required: true

  # Loaded modules on the left; the chosen module's functions on the right,
  # each a toggle, with "Whole module" on top.
  defp picker(assigns) do
    all = functions_of(assigns.modules, assigns.pick_mod)
    needle = needle(assigns.fq)
    whole? = {assigns.pick_mod, :_, :_} in assigns.picked
    picked? = fn {f, a, _} -> whole? or {assigns.pick_mod, f, a} in assigns.picked end

    shown =
      all
      |> Enum.filter(fn {_f, _a, exported?} = fun ->
        case assigns.ff do
          :all -> true
          :exported -> exported?
          :local -> not exported?
          :picked -> picked?.(fun)
        end
      end)
      |> Enum.filter(&matches?(&1, needle, assigns.syntax))

    assigns =
      assign(assigns,
        all: all,
        needle: needle,
        whole?: whole?,
        picked?: picked?,
        groups:
          [
            {"Exported", Enum.filter(shown, &elem(&1, 2))},
            {"Not exported", Enum.reject(shown, &elem(&1, 2))}
          ]
          |> Enum.reject(fn {_t, fns} -> fns == [] end),
        counts: %{
          all: length(all),
          exported: Enum.count(all, &elem(&1, 2)),
          local: Enum.count(all, &(!elem(&1, 2))),
          picked: Enum.count(all, picked?)
        }
      )

    ~H"""
    <div class="picker">
      <div class="picker-modules">
        <div class="picker-search">
          <input
            type="search"
            name="pick_q"
            form="pick-form"
            value={@pick_q}
            placeholder="Filter modules"
            phx-debounce="150"
            autocomplete="off"
            aria-label="Filter modules"
          />
          <button
            type="button"
            class="secondary small-btn"
            phx-click="refresh_modules"
            title="Reload the module list"
          >
            ↻
          </button>
        </div>
        <p class="muted small">
          {length(@shown_modules)} of {Format.number(length(@modules))} loaded modules
        </p>
        <ul class="modules">
          <li
            :for={mod <- @shown_modules}
            class={[
              mod == @pick_mod && "selected",
              Enum.any?(@picked, &(elem(&1, 0) == mod)) && "has-picks"
            ]}
          >
            <a href="#" phx-click="pick_module" phx-value-mod={mod}>
              {Format.name(mod, @syntax)}
            </a>
          </li>
        </ul>
      </div>

      <div class="picker-functions">
        <p :if={!@pick_mod} class="muted small">
          Choose a module to profile all of it or some of its functions.
        </p>
        <div :if={@pick_mod} class="fn-head">
          <h3 class="mono">{Format.name(@pick_mod, @syntax)}</h3>
          <button
            type="button"
            id="pick-whole"
            class={["small-btn", if(@whole?, do: "on", else: "secondary")]}
            phx-click="pick"
            phx-value-mod={@pick_mod}
            phx-value-fun="_"
            phx-value-arity="_"
            aria-pressed={to_string(@whole?)}
          >
            {if @whole?, do: "✓ Whole module", else: "Whole module (#{@counts.all} functions)"}
          </button>
        </div>
        <div :if={@pick_mod} class="fn-tools">
          <input
            type="search"
            name="fq"
            form="pick-form"
            value={@fq}
            placeholder="Search functions: name or name/arity"
            phx-debounce="100"
            autocomplete="off"
            aria-label="Search functions"
          />
          <div class="seg" role="group" aria-label="Show">
            <button
              :for={
                {f, label} <- [
                  all: "All",
                  exported: "Exported",
                  local: "Not exported",
                  picked: "Picked"
                ]
              }
              type="button"
              class={["seg-btn", @ff == f && "active"]}
              aria-pressed={to_string(@ff == f)}
              phx-click="pick_ff"
              phx-value-f={f}
            >
              {label} <span class="muted">{@counts[f]}</span>
            </button>
          </div>
        </div>
        <div :if={@pick_mod} class="fn-panel picker-fns">
          <p :if={@groups == []} class="muted small fn-none">No functions match.</p>
          <section :for={{title, fns} <- @groups} class="fn-group">
            <h4>{title} <span class="muted">{length(fns)}</span></h4>
            <ul class="fn-grid">
              <li :for={{fun, arity, exported?} = item <- fns}>
                <button
                  type="button"
                  class={["fn-row", !exported? && "local", @picked?.(item) && "selected"]}
                  phx-click="pick"
                  phx-value-mod={@pick_mod}
                  phx-value-fun={fun}
                  phx-value-arity={arity}
                  disabled={@whole?}
                  aria-pressed={to_string(@picked?.(item))}
                  title={if @whole?, do: "Included: the whole module is picked"}
                >
                  <span class="fn-name mono">
                    <.highlight text={fn_name(fun, @syntax)} needle={@needle} />
                  </span>
                  <span class="fn-arity mono">/{arity}</span>
                  <span :if={@picked?.(item)} class="fn-badge trace">✓</span>
                </button>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </div>
    """
  end

  defp pick_text({m, :_, :_}, syntax), do: "#{Format.name(m, syntax)} (whole module)"
  defp pick_text(mfa, syntax), do: Format.mfa(mfa, syntax)
end
