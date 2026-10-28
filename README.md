# beamdash

An Erlang and Elixir node inspection tool built with Elixir and Phoenix
LiveView. It connects to a running Erlang or Elixir node and shows what is
happening inside it.

**[Usage guide with screenshots](docs/usage.md)** — connection, process inspection, memory and GC investigations, tracing, profiling, crash reports, and optional Jev analysis. Includes a [local demo](docs/demo.exs) to try the workflows.

**Status: milestones 1–4.**

- **Tabs:** in three groups: the node (System, Load, Apps, Memory), its
  processes (Processes, GC, Crashes) and tracing (Trace, Seq, Profile);
  Settings is the ⚙ at the end, next to the `erl`/`ex` syntax switch.
  Hovering a tab shows its full name and shortcut. Tabs that do not fit
  move into **More ▾** (never the current one). Keyboard: `g` then a key
  opens a tab (`g s` System, `g n` Nodes, `g l` Load, `g a` Apps, `g m` Memory, `g p`
  Processes, `g c` GC, `g x` Crashes, `g t` Trace, `g q` Seq, `g f`
  Profile, `g ,` Settings); `?` lists them. Not while typing in a field.
- **Connection bar, on every tab:** on its own line under the tabs,
  aligned right: node and cookie with Connect while disconnected; the node
  with Disconnect once connected, whichever tab you are on (all open tabs
  follow). Below it, on its own line: the node's OTP
  release, process count and memory, refreshed every 2 s. The last node and
  cookie that connected fill the form again, also after a restart (see
  below; **Settings → Forget** clears them). With **Settings → Reconnect
  automatically** on, a connection lost because the node went down (or its
  kubectl tunnel failed) is made again the same way, after 1, 2, 5 and
  10 s, then every 15 s; the bar shows "Reconnecting to …" with **Stop**.
- **System:** what Observer's System tab shows, with its labels: System
  and Architecture (OTP and ERTS versions, architecture, word sizes, SMP,
  threads, async pool), Memory Usage (total, processes, atoms, binaries,
  code, ETS), CPUs and Threads (logical CPUs and schedulers: total, online,
  available), Statistics (up time, run queue, IO in/out), and System
  statistics / limit (atoms, processes, ports and ETS tables against their
  limits, with a bar, and the distribution buffer busy limit). Read by
  beamdash's agent with the same calls as `observer_backend:sys_info/0`,
  so the target needs no `runtime_tools`; refreshed every 10 s, as in
  Observer, or with Refresh.
- **Nodes:** the attached node and the nodes it is connected to
  (`nodes()`; **Show hidden** adds its hidden connections, beamdash's own
  left out), every 5 s. Clicking another node connects to it instead, with
  the cookie the attached node uses for it (`erlang:get_cookie/1` there).
  Direct connections only: a pod's peers aren't reachable through its
  kubectl tunnel.
- **Load Charts:** Observer's Load Charts: Scheduler Utilization (%), one
  line per scheduler with dirty CPU schedulers dotted, computed as Observer
  does from `scheduler_wall_time`; Memory Usage (total, processes, atom,
  binary, code, ETS); IO Usage (input and output per second). Sampled twice
  a second on the target, last 60 s, latest values in the legends. The
  scheduler legend is grouped (schedulers, dirty CPU schedulers) with each
  group's current average and a small bar per scheduler; hovering or
  focusing any legend item highlights its line. While
  the tab is open a small sampler on the target keeps `scheduler_wall_time`
  on; it stops, and the flag goes off, when you leave the tab or
  disconnect.
- **Applications:** Observer's Applications tab: the running applications
  (those with an application master) on the left, with version and
  description; on the right the selected one's process tree from its
  application master, found as Observer finds it (appmon_info's default
  link mode: follow links; a linked process is a child when its
  `$ancestors` start with the parent or, without ancestors, when it has the
  application's group leader). It is drawn as Observer draws it: grey
  rounded boxes left to right, one column per depth, a parent centred
  between its children, right-angled connectors, secondary links (to a
  process drawn elsewhere) in the highlight colour; the chart scrolls when
  it is large. Click a process to select it;
  **Process info** opens it on the Processes tab. The latest started
  application is selected first, as in Observer; refreshed every 5 s.
- **Processes:** connect as a hidden node and browse a live process table
  (sort, filter, auto-refresh every 2 s), including reductions per second,
  so what is busy *now* sorts to the top. gen_servers, gen_statems and
  supervisors (including `supervisor_bridge` and `DynamicSupervisor`) are
  marked with their own icon, detected from the callback module's behaviour, Erlang or
  Elixir, without messaging the process. A legend above the table shows how
  many of each there are; click an entry to list only those (or type
  `gen_server`, `gen_statem`, `gen_event` or `supervisor` in the filter).
  Click a process for a live
  detail panel (1 s refresh):
  - **reductions**: rate and total, with a one-minute trend;
  - **memory**: total and trend, young/old heap, stack, heap fragments,
    off-heap binaries and where messages are stored;
  - **garbage collection**: minor GCs since the last full sweep vs
    `fullsweep_after`, heap block, live data after the last GC, min/max heap
    settings, and a **Force GC** button that reports what was freed;
  - **mailbox**: queue length with its trend and the first 100 messages,
    oldest first. Above 100 queued messages they are only fetched when you
    ask (reading a mailbox copies all of it);
  - current stack; links drawn as on the Applications tab (this process
    highlighted, its linked processes in a column to the right, joined as
    Observer joins them); monitors and "monitored by" in the same boxes;
    each process shown by its registered name and clickable to open it
    here (ports and processes on other nodes are shown but not opened);
  - a **sys:trace** switch on gen_servers, gen_statems, gen_event managers
    and supervisors: it calls `sys:trace(Pid, true)` (and
    `sys:trace(Pid, false)` to switch off). What traced processes handle
    (calls, casts, messages, replies, new state) streams into the
    **sys:trace dock** along the bottom of the window, newest first,
    worded as sys:trace prints it, in the chosen syntax. Each traced
    process has its own panel there, the panels stacked one above the
    other. One panel is active and fills the dock; the others are
    minimized to a header bar that keeps counting new events ("12 new").
    Click a bar to make that panel the active one; a process you have just
    started tracing becomes active by itself. Each panel has Details,
    Clear and Stop. Drag the dock's top edge to change its height, or fold
    it away. Click a line for the whole event. As with any
    sys:trace, the same lines are printed on the target's console. Traced
    processes are highlighted in the table, and a "tracing" legend entry
    lists them. If beamdash disconnects or goes away, tracing is switched
    off on the target by itself.
  - **State** (gen_servers and gen_statems): `sys:get_state/2` in a panel
    of the dock, with records shown by field name when the module has debug
    info, and a gen_statem's state name apart from its data; Refresh reads
    it again. A busy process that does not answer within 3 s is reported.
  - **Supervisor tree** (supervisors): the whole tree under it in a dock
    panel (`which_children`, recursively, with a timeout): ids, kinds,
    names, strategies, memory, queued messages, children that are not
    running; click a process to open it here.
  - the panel is resizable: drag its left edge.

  Resize handles also work from the keyboard (focus one, then use the
  arrow keys; double-click or Home resets), and sizes are remembered in
  the browser.
- **Memory:** `erlang:memory()` every 2 s as one stacked bar (processes,
  binaries, ETS, code, atoms, other system) with a table of sizes, shares,
  change over the last 5 minutes and a trend line each; atom, process and
  ETS-table counts against their limits; memory allocated from the OS vs
  used (`recon_alloc`). Then **look for a leak** by kind:
  - *processes:* the top processes by memory, message queue or reductions
    (`recon:proc_count/2`), with their stack and, on request, their state
    (`sys:get_status/2`);
  - *binaries:* the top holders of binary memory, "garbage collect every
    process" with before/after, and "find binary leaks" (`recon:bin_leak/1`:
    who released the most binaries when collected). A big drop means
    processes held binaries they no longer used; a slice of a big binary
    keeps all of it unless copied (`binary:copy/1`);
  - *ETS:* every table with owner, rows and memory, and how much each has
    grown since the page was opened (the list refreshes every 5 s).

  recon is a dependency of beamdash. It is used from the node if the node
  has it; otherwise beamdash loads its copy into the node (never over the
  node's own). Without recon, built-in equivalents are used; the page says
  which.
- **GC:** collections and bytes reclaimed per second across the node, with
  a two-minute trend, and every process's heap and GC settings (refreshed
  every 2 s; pause it, since sampling asks every process): memory, heap,
  old heap and minor GCs since the last full sweep, with the same kind icons
  and legend filters as the Processes list. Click a process for the same
  panel as on Processes (live every second, resizable, × to close;
  `/gc?pid=<0.80.0>` opens it directly), about its garbage collection:
  - heap by generation (young, old, stack) and one-minute trends of memory
    and old heap;
  - minor GCs against `fullsweep_after` (when they meet, the next
    collection is a full sweep), heap settings and referenced binaries;
  - **Force GC**, reporting what was freed;
  - a **GC trace** of that process for 1–30 s (at most 200 collections):
    each minor collection and full sweep, how long it took and the heap
    before and after. It stops on its own, when you leave the page or close
    the panel, and leaves a tracer someone else attached alone;
  - **Jev: next step** (below).

  The panel links to the process on the Processes tab, which links back.
- **Tracing**: pick a module and click functions to pick them, as on the
  Profile tab: several at once, from any modules (a ✓ marks them in the
  list, a dot marks modules with picks; click again to unpick, or **Clear
  selection**).
  **Trace N functions** starts them all, **Stop N traces** stops them, and
  **Seq trace** seq traces them all; with exactly one picked, its **Call
  graph** is offered too. Watch calls, return values, exceptions, durations and call
  stacks arrive live. Click a call (or press Enter on it) to open its
  arguments, result and call stack right under it; click again to close. gen_server state shows up as records (`#state{...}`)
  when the module has debug info. Traces are re-applied when a module is
  hot-reloaded, and tracing stops itself if the target can't keep up.
  Each trace counts down from a call limit set next to the Trace button
  (30 by default, for each picked function; empty means no limit): every call takes one off, the
  count left shows on the trace, and at 0 the trace switches itself off.
  Calls that arrive while it is being switched off are not logged, so the
  log holds exactly that many calls.
  With no function picked, **Trace all N functions** traces every
  function of the module, local ones included (`mod:_/_`, i.e.
  `dbg:tpl({Mod, '_', '_'}, ...)`); its call limit counts calls of any of
  them. It is offered only while none of the module's functions is traced
  on its own (the two would clear each other), and not for the modules the
  tracing itself runs in (`erlyberly`, `dbg`, `erlang` and other preloaded
  runtime modules).
  A module's functions are listed in a grid, exported and not exported
  apart, with a search box (a name, or `name/arity`; Enter picks the first
  match) and All / Exported / Not exported / Traced filters. Drag the grip
  under the list to change its height, and the module list's right edge to
  change its width.
- **Seq trace:** pick functions and click “Seq trace”; every call of them starts
  a seq_trace token; the messages it causes, across processes, are drawn
  as a sequence diagram. gen_server replies (sent to a process alias since
  OTP 24) are shown going back to the caller. On the Seq trace tab, × on a
  function stops its seq trace and **Stop all** stops every one.
- **Profile** (OTP 27+ targets): OTP's `tprof` measures, per function,
  call time, call counts or heap allocated (Memory), for the modules and
  functions you pick as on the Tracing tab (a filterable list of loaded
  modules, then **Whole module** or single functions from its grid, with
  search and Exported / Not exported / Picked filters; picks show as
  chips) or type (`mod`, `mod:fun/arity`, Elixir `Mod.fun/arity`, `_`
  for anything), in all, new, existing or chosen processes (and what they
  spawn), for a set number of seconds. Results refresh while it runs and
  show as a sortable, filterable table, in total or per process. tprof
  runs in its own trace session, so it does not clash with tracing; if
  beamdash disconnects, profiling stops on the target by itself.
- **Call graph:** what a function calls, as an expandable tree, from an
  xref index of the target's code (built once; OTP and Elixir standard
  libraries are not indexed, so calls into them are leaves).
- **Crashes:** crash reports (gen_servers, supervisor children, Tasks…
  dying abnormally) as they happen, with reason, stack and process info.
- **Erlang / Elixir syntax** switch for every term, function name and pid
  in the UI. Erlang syntax prints records as `#cart{items = [...]}`.

## Run it

Requires Elixir 1.15+ and Erlang/OTP 25+ (`brew install elixir`).

```bash
cd ~/projects/erl/beamdash
mix setup            # fetch deps and compile
mix phx.server       # open http://localhost:4000
```

In another terminal, start something to inspect:

```bash
erl -sname foo -setcookie abc
```

Then connect to `foo` (or `foo@yourhost`) with cookie `abc`, from the bar at the
top of any tab.

beamdash starts Erlang distribution itself on first connect, picking short or
long names to match the target, and restarts it automatically if a later
target needs the other mode (e.g. switching from a dotted direct target to
a kubectl pod's short, undotted name, or back) — no user action needed. You
can also start it as a named node: `iex --sname beamdash -S mix phx.server`,
but then beamdash can't switch modes for you, since Erlang won't let a
statically-started node's distribution be stopped and restarted; a target
needing the other mode fails with a clear error instead.

To connect to a node running in a Kubernetes pod instead, switch the
connection bar to **kubectl**, pick the **Cluster** (one entry per
kubeconfig file under `~/.kube`, or the directory set in **Settings** —
beamdash passes it to `kubectl` directly,
no shell-level context switch needed), enter the namespace, pick the pod,
and pick the release binary (found from the running BEAM's release root,
so Mix releases in `/app` and relx releases in e.g. `/opt/<name>` both work). beamdash reads the node
name and cookie off the pod itself, then opens the `kubectl port-forward`
tunnels distribution needs to reach it; no `node@host` or cookie to type.

## Jev: suggested next step (optional)

Both process panels (Processes and GC tabs) end with **Jev: next step**:
TypeSafe's [Jev](https://docs.typesafe.ai) model picks which investigation
should come next (message backlog, CPU work, heap growth, retained binaries,
GC activity, what it waits on, idle memory, or no clear issue). It is a
suggestion, never a diagnosis, and nothing is changed on the node.

- **beamdash does the arithmetic.** It sends derived facts, not just raw
  samples: queue growth per second, memory change over the window,
  reductions rate (mean, peak), binary bytes against process memory, old-heap
  share, the process's status, a wait category ("OTP receive loop",
  "application code", "I/O", "hibernated"…, never the function), OTP kind,
  and its rank and share among the node's processes. The GC panel adds heap
  and binary trends and the GC trace summary (collections per second, mean
  and longest pause, share of time in GC). A short raw series goes along as
  backup.
- **It asks only with enough evidence.** Analyze stays disabled while the
  panel collects history ("collecting history · 6 of 15 s"); keep the
  process selected during representative work.
- **The answer is shown as given.** When the top two options are close,
  both are shown ("Investigate message backlog *or* Inspect what it waits
  on"), with the four most likely options, the model, and how many samples
  over how long it was based on. (Jev's `confidence` describes how peaked
  its probabilities are, so a low value is shown, never replaced.)
- **What is sent** is listed under the button, with the exact payload after
  an analysis. Never names, pids, modules, stacks, messages or state.
  Requests go only to `https://api.typesafe.ai/v1/systemone`, only when you
  click. TypeSafe's documentation does not say how long requests are kept;
  calls may be charged.

Set `TYPESAFE_API_KEY` in the environment that starts beamdash. Jev is then
on (setting the key is the opt-in); **Settings → Enable Jev analysis** turns
it off or on for all open tabs until beamdash restarts. The model is pinned
(`jev-1.13.0`); `TYPESAFE_MODEL` selects another. If the system's CA
certificates are unavailable, set `TYPESAFE_CACERTFILE` to a PEM bundle; TLS
verification stays on. The key stays on the beamdash host: it is never sent
to the browser or the inspected node.

`enabled: false` under `config :beamdash, Beamdash.Jev` in
`config/config.exs`, or `JEV_ENABLED=false` (or `0`, `no`, `off`) in the
environment, disables Jev entirely: on every tab, every Jev element (the Ask
box, triage, the process, GC, memory and sequence sections, and the Settings
switch) is hidden and no request is ever made. The environment variable wins
when both are set. Without `TYPESAFE_API_KEY` the UI is hidden the same way.
Turning the Settings switch off hides the same elements on every tab; only
the switch itself stays, so Jev can be turned back on.

### Trying Kev instead of Jev

[Kev](https://github.com/jaredpalmer/kev) is a family of open, self-hosted
decision models (0.8B to 27B, built on Qwen) that serves the same
`/v1/systemone` API. beamdash can send every request above to a Kev server
instead of TypeSafe, so the measurements never leave your network:

```sh
# in a Kev checkout
uv sync --extra serve
uv run --extra serve python -m kev.serve --run jaredpalmer/kev-4b --port 8009

# beamdash
KEV_URL=http://127.0.0.1:8009 iex -S mix phx.server
```

`KEV_URL` turns Kev on; `KEV_API_KEY` is sent only to Kev (when its server
sets one; TypeSafe's key is never sent to it), `KEV_MODEL` names the model
shown (default `kev-latest`) and `KEV_TIMEOUT` (ms, default 120000) allows
for a slower machine. With both Jev and Kev configured, **Settings → Suggestions
model** switches between them for every open tab, and the choice is saved;
`DECISION_BACKEND=jev|kev` picks one when none is chosen there. With only
`KEV_URL` set, Kev is used. Labels already shown in other open tabs change
to the new name when the page is next opened.

Compare the two before relying on Kev:

```sh
TYPESAFE_API_KEY=... mix beamdash.jev_eval --backend jev
KEV_URL=http://127.0.0.1:8009 mix beamdash.jev_eval --backend kev
```

Each prints how many scenarios it got right, the time of each request, and
the mean and slowest. Kev's smaller models accept states of up to about 8k
tokens; a longer one (the triage of 30 processes is the largest) is
refused with a 422, shown as "may be too long for this Kev model".

### More Jev, same rules

The same rules apply to these too: beamdash measures, Jev only picks one
of a fixed set of options, nothing identifying is sent, and every request
is shown under "What is sent to TypeSafe".

- **Ask beamdash** (under the header, every tab): type a question such as
  "who is leaking binaries?" or "trace demo_shop". Jev picks the view that
  answers it (processes by memory, queue or CPU, triage, a memory view,
  the health check, GC, Tracing, Seq trace, Profile, Crashes…) and
  beamdash opens it; when two views fit about equally, both are offered.
  A module named in the question is matched against the node's loaded
  modules here and opened on the Tracing or Profile tab. Only the typed
  question is sent.
- **Triage** (Processes tab): **Jev: triage busiest processes** asks, in
  one request, about each of up to 30 of the busiest processes (by memory,
  queue and reductions rate; beamdash's own helpers left out), sent as
  anonymous ids `p1, p2, …` with their 30-second trends, rank on the node,
  status, wait category and OTP kind. Processes whose answer is an
  investigation are flagged in the table (⚑ and the suggestion); **Show
  only flagged** narrows the table to them. Opening a flagged process shows
  the flag at the top of its panel with **How to check it**: a few steps for
  that investigation, written by beamdash (not Jev) from what the panel
  knows, with buttons where beamdash can take the step (Force GC, State,
  the Tracing/Profile/GC tab on that module or process, or the process a
  pending call is waiting on). A call waiting for another process's reply
  (`gen:do_call`) is sent as its own wait category, `call_reply`, not as
  an idle OTP loop.
- **Node memory health** (Memory tab): per kind of memory (processes,
  binaries, ETS, atoms, code, other), its size, share, change and growth
  over the window, the atom/process/ETS limits used and allocated vs used
  memory. Jev names the kind that needs attention, and a button opens its
  leak view.
- **Message-flow pattern** (Seq trace page): from the recorded messages,
  counts by kind (call, reply, cast), call-to-reply latency and unanswered
  calls, fan-out and fan-in (replies excluded), concentration on one
  process, messages per process pair, chain depth and burstiness. Jev picks
  request storm, fan-out, chatty exchange, deep chain, slow responder or
  normal flow.

`/?triage=1` and `/memory?check=1` run the triage and the health check as
soon as enough history is collected; Ask uses them.

**Checking the suggestions.** `mix beamdash.jev_eval` sends fixed
scenarios with a known right answer and reports how many Jev gets right:
7 process and 6 GC cases (a growing mailbox, a hot loop, heap growth,
retained binaries, an idle memory hog, a blocked process, healthy ones),
6 memory pictures, 6 message flows, 14 typed questions and one table of
12 processes to triage. Run it before changing `TYPESAFE_MODEL` and
compare (`--model jev-latest`; `--only memory,seq,route,triage` to run
some sets; `--strict` exits 1 on any miss). `TYPESAFE_ENDPOINT` points
beamdash at a stand-in instead of TypeSafe's API, for testing only.

## Plugins

A plugin adds pages for one application (riak_core, say) to a **Plugins**
menu, shown while that application runs on the attached node. Add one in
**Settings → Plugins**: type a Mix dependency and click **Add**.

```elixir
{:riak_core_plugin, "~> 0.1"}                                 # Hex (needs `mix local.hex`)
{:riak_core_plugin, git: "https://github.com/…", tag: "0.0.1"} # Git: tag:, branch: or ref:
{:riak_core_plugin, path: "~/src/beamdash-riak-core-plugin"}  # a local folder
```

beamdash fetches the plugin's own source (never its deps), checks it,
compiles it and loads it, with no restart. Plugins live in `plugins/`
under the configuration folder (`~/Library/Application Support/beamdash`
on macOS, `~/.config/beamdash` on Linux), listed in `plugins.json`;
`config :beamdash, :plugins_dir` moves it. A path plugin is compiled from
its folder, which stays where it is (it may not be inside the plugins
folder); **Rebuild** recompiles it after you change it. Each plugin is
**active** (a supported application runs at a matching version),
**waiting** (none runs), or **incompatible** (one runs at another version).

**Trust:** a plugin runs inside beamdash with full access to the nodes you
connect to, and compiling it runs its code. Add only plugins you trust.

**Writing one:** the entry module does `use Beamdash.Plugin` (name, pages
and, optionally, `main:`, the page the Apps tab also shows for the
applications it supports; the first page by default), each page
`use Beamdash.Plugin.Page`. The supported applications
are `runtime: false` deps in `mix.exs`, which beamdash reads as data and
never runs. A plugin can't have other runtime deps: it may only use what
beamdash ships (Phoenix, LiveView, Jason…). Code on the node is called
only with `Beamdash.Plugin.rpc/5`. All modules sit under one top-level
prefix, which no loaded module may already use. Protocol implementations
have no effect, because beamdash's protocols are consolidated. See the
`Beamdash.Plugin` docs, and the riak_core plugin
([beamdash-riak-core-plugin](https://github.com/dskliarov/beamdash-riak-core-plugin))
as an example.

## How it works

```
LiveView (browser) ──▶ Beamdash.Target ──hidden connection──▶ target node
                                                               └─ :beamdash_agent
```

- **`Beamdash.Target`** owns the one connection. It sets the cookie for that
  node only, connects with `:net_kernel.hidden_connect_node/1` (so it never
  joins the target's cluster or shows in `nodes()`), monitors the node and
  notifies subscribers when it goes down.
- **`:beamdash_agent`** (`src/beamdash_agent.erl`) is loaded into the target
  with `:code.load_binary/3`. It gathers all process info in one RPC per
  refresh. If the target runs an older OTP that rejects the BEAM compiled
  here, the loader sends the module's abstract code and compiles it on the
  target instead. Reconnecting skips the load when the MD5 matches.
  Reading another process's info is a signal that process handles itself
  (about one reduction), so the agent asks for everything in one
  `process_info` call: an idle process you are watching shows about 1
  reduction/s of beamdash's own (2 on OTP 25 for gen_servers and other
  proc_lib processes).
- **Tracing agent:** loaded on connect, it runs the trace collector on the
  target using `dbg`.
- **`Beamdash.Tracer`** starts and stops traces through it. The
  collector sends trace messages straight to the Tracer's pid, so nothing
  is polled. The Tracer pairs each call with its return per process and
  keeps the last 2,000 entries.
- **`Beamdash.SysTracer`** switches sys:trace on and off through the
  agent, which also installs a sys debug function that copies each event to
  a collector process on the target. The collector sends events on in
  batches (at most 1,000 a second), watches beamdash and turns tracing off
  everywhere if beamdash goes away.
- **`Beamdash.SeqTracer`**, **`Beamdash.CallGraph`** and
  **`Beamdash.Crashes`** drive the seq_trace collector, xref
  analysis and error_logger handler. Seq trace results are polled once a
  second while a seq trace is active; crash reports are pushed.
- **UI:** `HomeLive` (`/`), `TraceLive` (`/trace`), `SeqLive` (`/seq`) and
  `CrashLive` (`/crashes`); `BeamdashWeb.Syntax` shares the syntax switch
  between pages. There is no Node.js toolchain: the Phoenix and LiveView
  JS are served straight from the deps.

Tracing uses `dbg`, so it needs `runtime_tools` on the target, and it will
conflict with anything else using `dbg` on that node at the same time.
Call graphs need `tools` (xref) on the target and modules compiled with
debug info. The crash-report handler is removed when you disconnect; if
the connection drops instead, it stays until you reconnect.

The UI listens on 127.0.0.1 only, since it can reach any node whose cookie you
type in.

After a successful connection the node and cookie are saved, as plain JSON,
in `last_connection.json` in your user config folder
(`~/Library/Application Support/beamdash` on macOS, `~/.config/beamdash`
on Linux), readable only by you, so the connection bar is filled in next
time. A failed attempt never replaces them. **Settings → Forget** deletes
the file; `config :beamdash, :last_connection_file, false` turns saving
off (or give it another path). Tests use a temporary file.

## Tests

```bash
mix test
```

The target and tracer tests start real nodes with `:peer` and check the
hidden connection, agent loading, process listing, wrong cookies, node-down
notifications, call/return pairing, exceptions, gen_server records, stopping
traces, hot code reload, the overload cut-off, seq traces (including local
calls and reply aliases), call graphs, crash reports and both syntaxes.

## Ideas for later

- OTP 27 trace sessions instead of global `dbg`, so beamdash no longer
  clashes with other tracers.
- Module source view (`get_source_code/1`).

## Tracing agent

The tracing agent is written in Elixir and runs on nodes **without Elixir**:
it calls only Erlang/OTP modules
(no `Enum`, `String`, interpolation, `inspect` or `rescue`).
`test/beamdash/agent_test.exs` checks the compiled module imports nothing
from Elixir and exercises it on plain Erlang nodes. Writing new code in it,
keep to the same rule.

The agent includes these compatibility and reliability improvements:

- `dbg:stop_clear/0` (deprecated in OTP 26) is only used on older nodes;
  newer ones use `dbg:stop/0`, which clears traces there.
- The seq_trace match spec no longer needs `dbg:fun2ms` (one spec for
  every arity, so the old 12-argument limit is gone).
- `erlang:get_stacktrace/0` (removed in OTP 23) replaced with
  `catch Class:Reason:Stacktrace`; `+` on strings replaced with `++`.
- `stop_trace/4` clears the trace pattern synchronously, so calls made right
  after stopping are no longer traced.
- After a hot reload, traces are re-applied directly instead of by the
  collector messaging itself (which raced with the reload notification,
  duplicated trace entries and printed `unknown trace {ok, Ref}`).
- Returns from the `code` module (watched only to detect reloads) are no
  longer reported as traces.
- seq_trace: the collector no longer crashes on messages sent to a process
  alias (every gen_server reply since OTP 24); the system tracer is set
  before `seq_trace/5` returns, so the first calls are not lost; new
  `stop_seq_trace/4`; call traces created by seq patterns are not logged.
- xref: a function outside the index (any OTP call) is a leaf instead of
  aborting the whole analysis; new `xref_analysis/5` with a depth limit;
  directories are indexed once instead of twice, without warnings, and
  Elixir's standard library is excluded.

## License

GPL-3.0-or-later (see `LICENSE`). The tracing agent is
Copyright (C) 2016 Andy Till and includes MIT-licensed
code from redbug (Mats Cronqvist) and a fun decompiler by Serge Aleynikov.
