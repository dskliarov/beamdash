# Multiple connections to one application

## Goal

Let beamdash stay connected to several nodes of the same application at
once: several pods of one Kubernetes deployment, or several nodes of one
direct application. Each browser session has a selected node that its pages
show, the logs combine every connected node with each line tagged by its
origin, and
saved connections are grouped by application, and a compare view puts the
processes and memory of up to three nodes side by side.

Without the setting, beamdash behaves exactly as today: one connection,
and a new connect replaces it.

## Terms

- **Application.** The identity that makes two nodes "the same app". For a
  Kubernetes connection it is the container image's repository (tag and digest
  left out); for a direct connection
  it is the node name prefix (the part before `@`, e.g. `api` for
  `api@host1`).
- **Connection.** One attached node with its own distribution link, cookie,
  kubectl tunnel (if any), and its own `Beamdash.Target` process.
- **Selected node.** The connection a browser session's pages show. It is
  kept in the session's Phoenix session cookie, so two browsers can select
  different nodes. A new session starts on the first connected node.

## Settings

- New checkbox on the Settings page: "Allow multiple connections". Default
  off.
- Stored like `auto_reconnect` (`Beamdash.Settings.multiple_connections?/0`,
  `put_multiple_connections/1`), in the same settings file and cached in
  `:persistent_term`.
- Turning it off disconnects every connection except the node selected by
  the session that turned it off, at once. That session's bar shows a notice
  naming what was disconnected. Another session whose selected node was
  disconnected falls back to the first remaining connected node. After that
  the usual single-connection behavior applies: a connect replaces the
  current node.

## Application identity

### Kubernetes

- The image is the `image` field of the container that beamdash connects
  to, read from the pod spec:
  `kubectl [--kubeconfig K] -n NS get pod POD -o jsonpath={.spec.containers[?(@.name=="C")].image}`.
- `Beamdash.Kubectl.pod_image(kubeconfig, namespace, pod, container, exec \\ &run_kubectl/1)`
  returns `{:ok, image}` or `{:error, {:image_lookup_failed, reason}}`,
  with the same shape and `catch` as `list_pods/3`. A single-container pod
  reads `container` as nil and uses the only container.
- The application is the image's repository: the image with its tag and
  digest removed. `registry:5000/team/api:1.4.2` and
  `registry:5000/team/api@sha256:…` both give `registry:5000/team/api`.
  Two pods are the same application when their repositories are equal, so
  a rolling deploy with two tags is one application. A registry port is
  not a tag: only a colon after the last `/` starts a tag.
- `Beamdash.Kubectl.image_repository/1` does this split. It is a pure
  function, tested on its own.

### Direct

- `app = prefix of the node name before "@"`. Two nodes are the same
  application when their prefixes are equal, e.g. `api@web-1` and
  `api@web-2`.
- No lookup is needed, so this is computed from the node name everywhere
  it is shown.

### Rule

- The first connection of a session fixes the application. Any later
  connection must have the same `app` (repository or prefix) or it is refused:
  `{:error, {:different_application, app}}`, shown in the connection bar as
  "Connected to <app>. <node> runs <other>, so it is not added."
- A direct and a Kubernetes connection can never share an application,
  since their identities are of different kinds.
- Disconnecting every connection clears the fixed application.

## Connections

### Processes

- One `Beamdash.Target` per connection. The first connection uses the
  well-known name `Beamdash.Target` (started by the application, so the
  single-instance services keep their default node); further connections
  are started under a `DynamicSupervisor` and addressed by pid. The existing
  `Target` API already accepts a `server` argument, so nothing else in the
  `Target` code changes shape.
- `Beamdash.Connections` (new) is the single entry point: `list/0`
  (connected nodes with their app and source), `add/…` (runs the
  application rule, then starts a `Target` and connects), `remove/1`,
  `server_for/1`, and `app/0`.
- With the setting off, `Connections` holds at most one connection, and
  `connect` removes the current one first, as today.

### Pages

- Every LiveView already reads the connection through
  `BeamdashWeb.Connection`'s `on_mount` hook. The hook also keeps
  `@conn.selected_node` (this session's selected node) and `@conn.server` (its
  `Target` name).
- Pages stop calling `Target.*` with the default name and call it with
  `@conn.server` instead. This is a mechanical change over the existing
  call sites; it is the largest part of the work.
- The selected node is per browser session. It is stored in the Phoenix
  session, so each browser keeps its own choice. A LiveView cannot write
  the session cookie, so choosing a node in the selector is a link to
  `GET /connections/select?node=NAME&return_to=PATH`, which stores the
  choice and redirects back. `return_to` must be a path on this app (one
  leading `/`, no backslash); anything else goes to the Referer's path, or
  `/` when there is none, so the redirect cannot leave the app. A session with no choice yet, or whose chosen
  node is no longer connected, shows the first connected node; that fallback
  is computed on each mount and is not stored. Changing it in one session
  does not affect the others.
- Pages that read a node's state (processes, modules, memory, traces,
  GC, system) show the session's selected node only. Their header names the node,
  so the user never has to guess which pod they are looking at. The
  compare view (below) is the exception.

### Connection bar

- With one connection the bar looks as it does today.
- With two or more, the bar shows a node selector: a dropdown listing each
  connected node with a status dot and its application. Choosing one sets
  the selected node for this session only.
- Each connected node in the bar has its own disconnect action. "Connect"
  adds a connection when the setting is on and replaces it when off.
- The bar keeps one kubectl progress line for each connection that is
  connecting.

### Auto-reconnect

- Per connection, as today: a lost connection is retried by its own
  `Target` in the background. The bar shows "reconnecting" against that
  node only.

### Saved connections

- `Beamdash.LastConnection` gets an `app` field on each entry, saved when
  the connection succeeds: the image for Kubernetes, the prefix for a
  direct node.
- The bar's saved list is grouped by `app`, most recent group first, with
  the app as the group heading and each node under it.
- Entries saved before this change have no `app`. Direct entries get it
  from their node name when read. Kubernetes entries have no image on
  file, so they are listed under "Unknown application" until they
  connect once, which records the image. This needs no migration.
- The cap is 10 entries with the setting off and 30 with it on. Turning the
  setting off does not delete saved entries; the list is trimmed to 10 the
  next time a connection is saved.

## Compare view

- A Compare page (`/compare`, a nav entry next to Processes and Memory)
  shows the processes and memory of up to three connected nodes side by
  side, one column per node.
- Nodes are chosen with checkboxes, one per connected node. The first
  three connected nodes start checked. A fourth cannot be checked; its
  checkbox is disabled with the note "Compare shows up to three nodes".
- Compare needs at least two connections. With one, the page says "Connect
  a second node to compare" and shows no columns.
- Each column has the node's name and application in its header, a memory
  breakdown in the same categories as the Memory page, and its process
  list with the Processes page's columns and sorting. The lists are not
  merged: each column sorts on its own.
- A process-name filter applies to every column at once, so the same
  process can be read across nodes.
- Each column refreshes on the same tick as its node's pages. A node that
  fails shows its error in its own column; the other columns keep loading.
- A node that disconnects keeps its column with its last data, greyed,
  marked "disconnected".
- The checked nodes are kept in the page's socket state, like the Logs
  checkboxes: they last for this visit and are not saved.
- The three-node limit applies to this page only. Running services (below)
  is not limited.

## Logs

- The `Beamdash.Logs` service keeps one stream per connected node, each
  with its own log-handler attach and kubectl log stream (where it is a
  kubectl connection). Each stream tags its entries with the node they came
  from.
- The Logs page shows the combined stream, merged by timestamp.
- Each row shows its origin node, with the same color for the same node
  across the page.
- **Node selection.** A row of checkboxes above the stream, one per node
  that has entries on the page: the connected nodes, plus any node that
  disconnected while the page held its entries. Checking or unchecking a
  node shows or hides its entries.
  - All nodes start checked. The choice lives in the page's own socket
    state: it lasts for this visit to the Logs page and is not saved.
  - The checkboxes are independent of the session's selected node. The Logs
    page always combines every connected node, for every session; only this
    session's view narrows.
  - Hidden nodes keep collecting. Unchecking a node does not stop its
    stream, so checking it again shows what it logged meanwhile, within
    the same buffer limit as the rest of the stream.
  - With no node checked, the page shows "No nodes selected" instead of an
    empty table.
  - With one node only (the setting off, or a single connection), the
    checkbox row is hidden.
- The existing level, text and pod filters apply to the checked nodes,
  on the merged stream.
- When a node disconnects, its stream stops. Its entries stay on the page,
  marked as coming from a node no longer connected, until the page is
  cleared.

## Services on connected nodes

Today `Beamdash.Sampler`, `Beamdash.AnomalyMonitor`, `Beamdash.Tracer`,
`Beamdash.SysTracer`, `Beamdash.SeqTracer`, `Beamdash.Profiler`,
`Beamdash.Crashes`, and the memory and GC advisors are single named
GenServers. Each one can run an instance per connected node, so it can run on
several nodes at once.

- Start and stop apply to a chosen set of nodes. The default is every
  connected node, so "Run on all connected nodes" starts the service on each
  one at once. A single node can also be started or stopped on its own.
- Each node's run is independent. If one node fails or disconnects, the
  others keep running and only that node's run stops.
- Sampler and Crashes start on every connection as soon as it connects, the
  primary and extra ones alike (Sampler only while storing is on). A stop
  control ends one node's run and leaves the others running.
- The anomaly monitor and the tracers start idle on a connection and run only
  when a page starts them on that node. Connecting never starts them.
- Service instances are global: one per connection, shared by every browser
  session. Stored history is keyed by node. A session's pages show results
  for its own selected node. Changing it in one session does not change what
  another session shows, and switching back shows the earlier data.
- Results from every running node are tagged with their node: sampler
  points, anomaly episodes and trace results. Their pages show the session's
  selected node by default and take a node filter, like the Logs page, to include
  others.
- A trace, a profile or a `sys` trace stays on the node it was started on
  until it stops, whatever any session selects. Its page shows that node.

### Instances (phase 1b)

- Every service takes a `target` option, the `Target` it reads from, and a
  `name` option (`nil` for an unnamed instance). Its default source reads
  through that `target`, so an instance never reads another node's data.
- The primary connection keeps the singleton names (`Beamdash.Sampler`, …),
  started by the application as today. Pages that do not yet take a
  connection keep calling them, so nothing changes for them.
- Each extra connection is one supervisor under
  `Beamdash.Connections.Supervisor`. It holds that connection's `Target` and
  one unnamed instance of each idle service: AnomalyMonitor, Tracer,
  SysTracer, SeqTracer and Profiler. The supervisor is removed with the
  connection, which ends every instance on it.
- Logs, Sampler and Crashes are also started on each extra connection, when it
  connects. Sampler is started only while storing is on, as at startup, and
  reads its connection's Logs instance.
- SeqTracer is given its connection's Tracer by pid.
- Instances are `:temporary`: one that crashes is not restarted, and its run
  ends.
- The memory and GC advisors are pure functions that pages call, not
  processes, so they have no instances.
- `Beamdash.Connections.service(server, module)` returns the pid of that
  connection's instance of `module`: the singleton for the primary, the child
  of the connection's supervisor otherwise.
- `Beamdash.Connections.stop_service/2` and `start_service/2` stop and start
  one service on one extra connection. A stopped instance is not restarted by
  its supervisor, so starting it again is an explicit call.
- An instance's in-memory state (rates, streaks, the monitor's open episodes)
  ends with its connection. History written to `Beamdash.Store` is keyed by
  node name and survives it.

## Pids and node names

- `Beamdash.Target.localize_pid/2` and `parse_pid/2` already key their
  per-node index by node name, so pids from two connected nodes do not
  collide. Links built from one node's pages are only valid for that node;
  opening one in a session whose selected node differs switches that session's
  selection to the node the link names, when that node is connected. Other
  sessions are not affected.

## Errors

- A second connection to the same node: no new connection; the session selects the
  existing one and a note says so.
- A different application: refused, nothing changes (see Rule).
- Image lookup fails for a Kubernetes pod: the connection is refused with
  the kubectl error; the rule cannot be checked, so the pod is not added.
- Setting turned off with several connected: every connection except the
  node selected by the session that turned it off is disconnected, and that
  session's bar says which ones (see Settings).

## Tests

- `Beamdash.Settings`: the checkbox defaults to off and persists.
- `Beamdash.Kubectl.image_repository/1`: strips a tag, a digest, or both;
  keeps a registry port (`registry:5000/app` stays as it is).
- `Beamdash.Kubectl.pod_image/5`: parses the image, passes
  `--kubeconfig` and the namespace, returns the error tuple on a non-zero
  exit and on raise. Uses the injected `exec` function, like
  `list_namespaces/2`.
- `Beamdash.Connections`: the application rule (same app accepted,
  different app refused, direct and kubectl never mix, cleared when empty),
  turning the setting off disconnects every connection except the one selected
  by the session that turned it off, and a second connection to the same node
  selects it in that session.
- `BeamdashWeb.Connection` (session selection): a new session starts on the
  first connected node; two sessions select different nodes; a disconnect
  falls back per session.
- `Beamdash.LastConnection`: entries get an `app`; grouping of mixed and
  legacy entries; "Unknown application" for kubectl entries without an
  image; the cap is 10 with the setting off and 30 with it on, and turning
  it off keeps entries until the next save.
- `Beamdash.Logs`: two streams merge by timestamp; each entry carries its
  node; a stopped stream keeps its entries.
- `logs_live_test.exs`: a checkbox per node with entries, all checked by
  default; unchecking hides that node's rows and keeps its stream; no node
  checked shows "No nodes selected"; the row is hidden with one node.
- `compare_live_test.exs`: a fourth node cannot be checked; fewer than two
  connections shows "Connect a second node to compare"; a failing node's
  column shows its error while the others load; the name filter applies to
  every column.
- Services on connected nodes: sampler, anomaly and trace each run on two
  nodes at once; stopping one node's run leaves the other running; a node
  disconnecting stops only its own run; results carry their node.
- `connection_bar_test.exs`: the selector appears only with two or more
  connections; the saved list is grouped; a refused connection shows its
  message.
- Visual check: headless Chrome screenshots of the selector, the grouped
  saved list and a combined Logs page with two nodes.

## Decisions

1. **Image match.** The application is the image repository, tag and digest
   ignored. A rolling deploy with two tags is one application.
2. **Setting turned off with several connected.** Every connection except
   the node selected by the session that turned the setting off is
   disconnected at once, with a notice.
3. **Saved list cap.** 10 entries with the setting off, 30 with it on.
   Turning the setting off keeps saved entries; the list is trimmed on the
   next save.
4. **Traces and profiles.** They stay on the node they were started on
   until they stop, whatever the selection does.
5. **Compare page.** A separate `/compare` page, not a mode of the
   Processes and Memory pages.
6. **Compare node limit.** Up to three nodes, on the compare view only.
   Running services is not limited.
7. **Compare refresh.** Each column refreshes on the same tick as its
   node's pages.
8. **Service instances.** Sampler and Crashes start on every connection as
   it connects, as the primary does today. The anomaly monitor and the
   tracers start idle and run only when a page starts them on that node.
   Stopping a run, or the node disconnecting, ends that node's run.
9. **Logs selection.** The node checkboxes are not saved, and hidden nodes
   keep collecting.
10. **Selected node.** It is per browser session, kept in the Phoenix
    session. A new session starts on the first connected node. Service
    instances are global per connection; each session's pages read results
    for its own selection.
11. **Single-instance services.** Logs, the sampler, the anomaly monitor,
    the tracers, the profiler, crashes and the memory and GC advisors become
    per-connection instances from the first implementation phase, not later.
    Each connection gets its own instance, keyed by node name, like `Target`.

## Out of scope

- Merging the nodes' process lists or module lists into one view.
- Connecting nodes of different applications in one session.
- Reading the image of pods that beamdash is not connecting to.
