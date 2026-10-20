defmodule ExberlyWeb.TriageGuide do
  @moduledoc """
  How to follow up a triage flag, shown in the flagged process's panel:
  a few concrete steps for the suggested investigation, using what the
  panel already knows (where the process is, what it monitors, its kind),
  with a button where exberly can take the step.

  The steps are written here, not by Jev: Jev only picked the
  investigation.
  """
  use Phoenix.Component

  alias Exberly.Format

  # OTP and runtime modules: not useful as "the module to trace/profile"
  @otp ~w(proc_lib gen gen_server gen_statem gen_event supervisor sys erlang timer
          prim_inet prim_file file_io_server gen_tcp gen_udp inet ssl io)a

  # Where a process waits for a gen call reply (GenServer.call, gen_statem:call, ...)
  @call_waits [{:gen, :do_call, 4}, {:gen, :do_call, 3}, {:gen, :do_send_request, 4}]

  attr :flag, :map,
    required: true,
    doc: "the triage verdict: %{choice, label, worth, alternative}"

  attr :details, :map, required: true
  attr :kind, :atom, default: nil
  attr :names, :map, default: %{}
  attr :syntax, :atom, required: true

  def box(assigns) do
    assigns = assign(assigns, steps: steps(assigns.flag.choice, assigns.details, assigns.kind))

    ~H"""
    <section class="triage-guide" id="triage-guide" aria-labelledby="triage-guide-title">
      <h4 id="triage-guide-title">
        <span class="jev-flag">⚑ {@flag.label}</span>
        <span class="muted small">
          triage · {round(@flag.worth * 100)}% worth a look{if @flag.alternative,
            do: " · or #{@flag.alternative.label}"}
        </span>
      </h4>
      <p class="muted small">How to check it:</p>
      <ol class="guide-steps">
        <li :for={step <- @steps}>
          <span><.text parts={step.text} /></span>
          <span :if={step.actions != []} class="guide-actions">
            <.action :for={a <- step.actions} action={a} names={@names} syntax={@syntax} />
          </span>
        </li>
      </ol>
    </section>
    """
  end

  attr :parts, :list, required: true

  # built as one piece of HTML: template whitespace would put spaces
  # around the code parts
  defp text(assigns) do
    assigns =
      assign(assigns,
        html:
          {:safe,
           Enum.map(assigns.parts, fn
             {:code, c} -> ["<code>", Phoenix.HTML.html_escape(c) |> elem(1), "</code>"]
             s -> Phoenix.HTML.html_escape(s) |> elem(1)
           end)}
      )

    ~H"{@html}"
  end

  attr :action, :any, required: true
  attr :names, :map, required: true
  attr :syntax, :atom, required: true

  defp action(%{action: {:event, event, label, title}} = assigns) do
    assigns = assign(assigns, event: event, label: label, title: title)

    ~H"""
    <button type="button" class="secondary small-btn" phx-click={@event} title={@title}>
      {@label}
    </button>
    """
  end

  defp action(%{action: {:panel, kind, label}} = assigns) do
    assigns = assign(assigns, kind: kind, label: label)

    ~H"""
    <button type="button" class="secondary small-btn" phx-click="open_panel" phx-value-kind={@kind}>
      {@label}
    </button>
    """
  end

  defp action(%{action: {:navigate, path, label}} = assigns) do
    assigns = assign(assigns, path: path, label: label)

    ~H"""
    <.link navigate={@path} class="btn-link small-btn">{@label} ↗</.link>
    """
  end

  defp action(%{action: {:open, pid}} = assigns) do
    assigns = assign(assigns, pid: pid, name: assigns.names[pid])

    ~H"""
    <button
      type="button"
      class="pid-link mono"
      phx-click="select"
      phx-value-pid={Format.pid(@pid, :erlang)}
      title="Show this process"
    >
      <span :if={@name} class="pid-name">{Format.name(@name, @syntax)}</span>{Format.pid(
        @pid,
        @syntax
      )}
    </button>
    """
  end

  @doc """
  The steps for a triage choice: `[%{text: parts, actions: actions}]`,
  where parts are strings and `{:code, string}`, and an action is
  `{:event, event, label, title}`, `{:panel, kind, label}`,
  `{:navigate, path, label}` or `{:open, pid}`.
  """
  def steps(choice, details, kind) do
    ctx = context(details, kind)

    choice
    |> do_steps(ctx)
    |> Enum.filter(& &1)
    |> Enum.map(fn {text, actions} -> %{text: List.wrap(text), actions: actions} end)
  end

  defp context(d, kind) do
    current = d[:current_function]
    app_mod = app_module(d[:initial_call], current)
    pid = Format.pid(d.pid, :erlang)

    %{
      current: current,
      current_text: Format.mfa(current, :erlang),
      in_call: current in @call_waits,
      waiting_on: for({:process, p} when is_pid(p) <- d[:monitors] || [], do: p) |> Enum.take(3),
      status: d[:status],
      queue: d.mailbox.length,
      sys?: kind in [:gen_server, :gen_statem, :gen_event, :supervisor],
      state?: kind in [:gen_server, :gen_statem],
      app_mod: app_mod,
      trace_link:
        app_mod && {:navigate, "/trace?mod=#{app_mod}", "Tracing: #{inspect_mod(app_mod)}"},
      profile_link:
        app_mod && {:navigate, "/profile?mod=#{app_mod}", "Profile: #{inspect_mod(app_mod)}"},
      gc_link: {:navigate, "/gc?pid=#{pid}", "GC tab"},
      force_gc: {:event, "gc", "Force GC", "erlang:garbage_collect(Pid)"},
      binaries: d.memory[:binary_bytes] || 0
    }
  end

  defp inspect_mod(mod), do: Format.name(mod, :erlang)

  # The application's module: the callback module of an OTP process (its
  # initial call is translated), else where it runs now, unless that is OTP.
  defp app_module({m, _, _}, _current) when m not in @otp, do: m
  defp app_module(_, {m, _, _}) when m not in @otp, do: m
  defp app_module(_, _), do: nil

  defp do_steps("inspect_blocking", c) do
    [
      if(c.in_call,
        do:
          {[
             "It is in ",
             {:code, c.current_text},
             ": a call (",
             {:code, "GenServer.call"},
             ", ",
             {:code, "gen_server:call"},
             ", ...) waiting for another process's reply. Current stack (below) shows which call."
           ], []},
        else:
          {[
             "See where it is: Running shows ",
             {:code, c.current_text},
             " and Current stack (below) the frames above it. ",
             "Typical waits: ",
             {:code, "gen:do_call"},
             " (a call waiting for another process's reply), ",
             {:code, "prim_inet"},
             " / ",
             {:code, "gen_tcp:recv"},
             " (a socket), ",
             {:code, "prim_file"},
             " (disk), or a ",
             {:code, "receive"},
             " in your own code waiting for a message that may never come."
           ], []}
      ),
      if(c.in_call,
        do:
          {[
             "A pending call monitors the process it called: ",
             "open it and see why it does not answer (busy, long queue, or blocked itself)."
           ], Enum.map(c.waiting_on, &{:open, &1})},
        else:
          {"If it is in a call, the process it called is in Monitors (a pending call monitors it): open it and see why it does not answer.",
           Enum.map(c.waiting_on, &{:open, &1})}
      ),
      {[
         "Watch it for a few refreshes: if Running stays the same while Mailbox grows, it is stuck; ",
         "if Running changes, it is slow rather than blocked."
       ], []},
      c.sys? &&
        {[
           "State and sys:trace need the process to answer system messages: ",
           "if it is blocked they time out, which itself confirms it."
         ], if(c.state?, do: [{:panel, "state", "State"}], else: [])},
      c.app_mod &&
        {[
           "Trace the function it waits in (or its callers) with a call limit to see how long each call takes and what it returns."
         ], [c.trace_link]}
    ]
  end

  defp do_steps("review_idle_memory", c) do
    [
      {[
         "Force a garbage collection. If memory drops a lot, it was garbage the idle process ",
         "would only collect on its next activity: hibernation would release it."
       ], [c.force_gc]},
      c.state? &&
        {"If it stays high, look at its State for data kept between messages: large lists, maps, caches or binaries.",
         [{:panel, "state", "State"}]},
      c.binaries > 0 &&
        {[
           "It references ",
           Format.bytes(c.binaries),
           " of off-heap binaries: if they stay after the collection, it keeps them (or slices of larger ones) alive."
         ], [c.gc_link]},
      {[
         "To fix it in the application: hibernate when idle (",
         {:code, "hibernate_after: ms"},
         " in the start options, or return ",
         {:code, ":hibernate"},
         " / ",
         {:code, "hibernate"},
         " from a callback), or move rarely used data to ETS or ",
         {:code, "persistent_term"},
         "."
       ], []}
    ]
  end

  defp do_steps("inspect_mailbox", c) do
    [
      {[
         "Open a few messages in Mailbox (below): their shapes tell who sends them and what for. ",
         "The chart shows whether the queue grows steadily (producers outpace it) or in bursts."
       ], []},
      c.sys? &&
        {"Turn on sys:trace (top of the panel) to see each message as it is handled and how often.",
         []},
      c.app_mod &&
        {"Profile its module to see where handling time goes, or trace its handler with a call limit.",
         Enum.reject([c.profile_link, c.trace_link], &is_nil/1)},
      {[
         "Fixes depend on the cause: make handling cheaper, add back-pressure (",
         {:code, "call"},
         " instead of ",
         {:code, "cast"},
         "), or spread the work over several processes."
       ], []}
    ]
  end

  defp do_steps("profile_cpu", c) do
    [
      c.app_mod &&
        {"Profile its module (call time) for a few seconds to see which functions take the work.",
         [c.profile_link]},
      {[
         "Glance at Current stack a few times: the frames that keep showing up are where it spends time."
       ], []},
      c.app_mod &&
        {"Trace the hot functions with a call limit to see their arguments and durations.",
         [c.trace_link]}
    ]
  end

  defp do_steps("inspect_heap_growth", c) do
    [
      {"Force a garbage collection and watch Memory: if it barely drops and keeps rising, data is being kept.",
       [c.force_gc]},
      c.state? &&
        {"Open its State and look for collections that only grow (lists, maps, queues, caches).",
         [{:panel, "state", "State"}]},
      {"The GC tab shows old-heap growth and full sweeps for this process.", [c.gc_link]}
    ]
  end

  defp do_steps("inspect_binaries", c) do
    [
      {[
         "Memory shows ",
         Format.bytes(c.binaries),
         " of off-heap binaries. Force a garbage collection: if they stay, the process still references them."
       ], [c.force_gc]},
      {[
         "Small slices of large binaries keep the whole binary alive: copy what you keep with ",
         {:code, "binary:copy/1"},
         ". Binaries passing through are freed only when the process collects."
       ], []},
      {"The GC tab shows binary heap sizes and lets you trace collections.", [c.gc_link]}
    ]
  end

  defp do_steps("inspect_gc", c) do
    [
      {"Open the GC tab and record a GC trace for a few seconds: count, pause times and share of time in GC.",
       [c.gc_link]},
      {[
         "Many minor collections suggest a small heap for its workload (",
         {:code, "min_heap_size"},
         "); frequent full sweeps suggest ",
         {:code, "fullsweep_after"},
         " or data that dies old."
       ], []}
    ]
  end

  defp do_steps(_other, _c),
    do: [{"Analyze it below for a suggestion about this process alone.", []}]
end
