# Logs tab

## Goal

A Logs tab showing the attached node's log lines. The source depends on how
beamdash connected:

- **Kubernetes** (`Target.connect_via_kubectl/6`): `kubectl logs -f` for the
  connected pod and container — includes history and anything written to
  stdout/stderr, plus a "Previous container" view (`--previous`).
- **Direct** (`Target.connect/2`): a logger handler installed on the node
  by the agent, streaming events from the moment of connect.

Newest lines at the top (same as Crashes).

## Knowing the connection's source

`Beamdash.Target` remembers how it connected. New `Target.source(server \\
__MODULE__)` returns `nil` (disconnected), `:direct`, or
`{:kubectl, %{kubeconfig: k, namespace: ns, pod: pod, container: c}}`
(container `nil` when none was picked). `status/1` and the
`{:beamdash_target, _}` events are unchanged.

## Kubernetes source

- `Beamdash.Kubectl.logs_args(kubeconfig, namespace, pod, container, opts)`
  builds the argument list: `[--kubeconfig K] logs -n NS POD [-c C]
  --timestamps --tail=1000` plus `-f` (`follow: true`) or `--previous`
  (`previous: true`).
- Live: `Beamdash.Logs` opens it as a Port (`:binary, :exit_status,
  :stderr_to_stdout, {:line, 16_384}`), so each line arrives on its own.
  Closing kills the OS process (same as port-forwards). If kubectl exits
  (pod restarted, RBAC refusal), the stream status becomes
  `{:ended, exit_status}` and the page offers "Reconnect"; the lines it
  printed (e.g. the kubectl error) are shown as normal lines.
- Previous container: a one-shot `kubectl logs --previous` run in a Task
  (not the GenServer), result kept as a separate list; the page switches
  between "Live" and "Previous container".
- `Beamdash.Logs.Parse.line/1` (pure) turns one line into an entry:
  - leading RFC 3339 timestamp from `--timestamps` → `at`;
  - JSON object with `"level"`/`"severity"` and `"msg"`/`"message"` →
    level + message (other keys become metadata);
  - default Elixir format `HH:MM:SS.mmm [level] message` (also
    `[level] message`) → level + message;
  - anything else → level `nil`, whole line as message.
  A line with no level that starts with whitespace (stack trace,
  multi-line message) is appended to the previous entry's message instead
  of becoming its own row.

## Direct source (agent, version 14 → 15)

In `src/beamdash_agent.erl` (kernel/stdlib only):

- `log_attach(Owner)`: removes a handler left by an earlier session, starts
  a collector registered as `beamdash_log_collector` that monitors
  `Owner`, and adds a logger handler `beamdash_logs` (module
  `beamdash_agent`, callback `log/2`). Returns `{ok, PrimaryLevel}`.
- `log/2` runs in the logging process: never crashes (`try ... catch _:_ ->
  ok`), formats the message on the node with `logger_formatter` (template
  `[msg]`), truncated to 8 KB, and sends the collector
  `#{at => Microseconds, level, pid, mfa, file, line, msg, meta}` where
  `meta` is the remaining metadata as `[{Key, Text}]`.
- The collector sends the owner `{beamdash_logs, Entries, Dropped}` every
  200 ms, at most 500 entries per batch; the rest are counted as dropped.
- When the owner goes down the collector removes the handler and exits.
  `log_detach()` does the same on demand; `Target`'s disconnect calls it
  next to the existing crash-handler removal.

## `Beamdash.Logs` GenServer

Started in the application tree after `Beamdash.Crashes`; modeled on it.

- On `{:connected, node}` it asks `Target.source/1` and starts the matching
  source; on disconnect it stops it. Keeps the last 2,000 entries
  (newest first), a `dropped` count, `status` (`:idle | :streaming |
  {:ended, code}`), `source` (`:direct | :kubectl | nil`) and the node's
  logger `level` (Direct only).
- Entries: `%{id, at, level, pid, where, message, meta}` (`where` = module
  or `mfa` text for Direct, `nil` for kubectl unless JSON gave one).
- API: `entries/1`, `info/1` (`%{source, status, level, dropped}`),
  `clear/1`, `subscribe/1`, `reconnect/1`, `previous/1` (kubectl only:
  `{:ok, entries} | {:error, reason}`, run outside the GenServer).
- Subscribers get `{:beamdash_logs, {:entries, new_entries}}` (batched,
  newest first), `{:beamdash_logs, :cleared}`, `{:beamdash_logs, {:info,
  info}}`.
- Test seams: `start_link` options `target:`, `source_fun:` (replaces
  `Target.source/1`), `logs_cmd:` (`fn args -> {executable, args} end`, so
  tests can run a shell script instead of kubectl).

## Logs tab (`/logs`, `BeamdashWeb.LogsLive`)

- Nav: Node group after Memory — `{"/logs", :logs, "Logs", "Logs", "o"}`.
- Header row: source badge ("kubectl logs pod/container" or "logger on
  node, level info"), level filter (all / debug / info / notice / warning /
  error and above), the filter text field (below), Pause/Resume ("+N new"
  while paused), Clear; Kubernetes adds Live / Previous container; an
  ended stream shows "Stream ended (exit N)" with Reconnect. Counts:
  "N of M lines" (shown / kept), dropped.
- Filter text field (`id="logs-filter"`, `type="search"`, placeholder
  `filter: words, -exclude, "exact phrase"`), the widest control in the
  row:
  - Matching is case-insensitive against message, where, pid and the
    metadata values of each entry.
  - Space-separated terms must all match; `-term` excludes entries
    containing it; `"two words"` matches the phrase as typed.
  - Applied as you type (`phx-change`, `phx-debounce="250"`), and to new
    lines as they arrive; Esc / the field's clear button empties it.
  - Combined with the level filter; also applies in the Previous
    container view.
  - Matched text in the Message column is highlighted (`<mark>`).
  - With a filter set and nothing matching: "No lines match the filter"
    with a Clear filter button.
  - Parsing and matching live in a pure `Beamdash.Logs.Filter` module
    (`parse/1` → `%{include: [..], exclude: [..]}`, `match?/2`), so they
    are unit-tested on their own.
- Table (same `.log` grid as Trace): Time (UTC), Level (coloured),
  Process, Where, Message (one line, ellipsis); clicking a row expands the
  full message and the metadata table.
- Repeated lines: consecutive similar lines are combined into one row
  with a repetition badge (`×37`).
  - Similar = same level, same where, and the same message once its
    variable parts are masked: pids (`<0.1.2>`), refs, UUIDs, hex ids
    (8+ hex digits), numbers (incl. decimals and units like `12ms`) and
    ISO timestamps. Masking is only used for the comparison; the row
    shows the newest line's real text.
  - Only consecutive lines combine (in the order shown, i.e. after the
    level and text filters are applied); a different line in between
    starts a new row.
  - The combined row shows the newest line's time and a "first at"
    time on hover.
  - Seeing the original lines of a group — three ways, from buttons on
    the combined row:
    1. **Expand** (clicking the row): the group opens in place and lists
       every original line it combined (not a sample), newest first, as
       normal rows (time, level, process, where, full message, with the
       masked parts highlighted so the differing values stand out).
       Each of these rows opens its own metadata on click. Clicking the
       group row again collapses it.
    2. **Show all like this**: sets a pattern filter to the group's
       masked signature. The table then shows every line in the kept
       buffer with that signature — also the ones in other, non-adjacent
       runs — ungrouped, in original order. A removable chip
       (`pattern: cache miss for key user:# ✕`) appears next to the text
       field; it combines with the level and text filters, and with
       "Group repeats" turned off implicitly while it is set.
    3. **Copy / Download**: copies the group's original lines as raw
       text to the clipboard, or downloads them as
       `<node>-<yyyymmdd-hhmmss>.log`. The same two buttons appear in the
       header for the current view (all lines that pass the filters).
       Done in the browser by a `LogExport` JS hook that receives the
       lines via `push_event("logs-export", %{name, text, mode})`.
  - Entries keep their original text in `raw` (the kubectl line as
    printed, with its timestamp; for Direct
    `"<ISO time> [<level>] <where> <message>"`), which is what Copy and
    Download output.
  - A new line similar to the top row increments its count in place
    (same row id, `stream_insert` at 0) instead of adding a row.
  - A "Group repeats" checkbox (on by default) turns it off to see every
    line. "N of M lines" still counts lines, not rows.
  - Counts reflect the lines Beamdash.Logs has kept (last 2,000); lines
    evicted from that buffer no longer count.
  - Pure `Beamdash.Logs.Group` module: `key/1` (masked signature),
    `mask_spans/1` (where the masked parts are, for highlighting),
    `group/1` (newest-first entries → rows, each row holding the ids of
    all its entries), `add/2` (rows + new entry → rows), so it is
    unit-tested on its own.
- LiveView stream, newest inserted at the top, limited to 1,000 rows;
  changing a filter, the grouping checkbox, or resuming resets the stream
  from `Logs.entries/1`.
- Not connected: the usual "Not connected" hint.

## Errors

- Agent RPC failures or `kubectl` missing: `info.status = {:ended, reason}`
  shown on the page; never crashes `Beamdash.Logs`.
- `Logs` never sets the connection bar's error.

## Tests

- `Parse.line/1`: timestamp prefix, JSON, default Elixir format with and
  without time, plain text, continuation lines.
- `Kubectl.logs_args/5`: follow, previous, container, kubeconfig.
- Agent on a peer: a line logged after `log_attach` arrives formatted;
  `log_detach` removes the handler; the handler is removed when the owner
  dies; dropped counting above 500 per batch.
- `Beamdash.Logs` on a peer: Direct entries arrive and reach subscribers;
  disconnect detaches; Clear. Kubernetes path with `source_fun` +
  `logs_cmd` (a `sh -c 'printf ...'` script): entries parsed, `{:ended,
  0}` after exit, Reconnect restarts.
- `Target.source/1` after a direct connect and after disconnect.
- `Filter.parse/1` and `Filter.match?/2`: single word, several words (all
  must match), `-exclude`, quoted phrase, case-insensitivity, matching on
  where/pid/metadata, empty filter matches everything.
- `Group`: masking of each variable kind and `mask_spans/1`; consecutive
  similar lines combine with the right count, first/last time and all
  entry ids; a different line in between splits; different level or
  where never combines; `add/2` increments the top row or starts a new
  one.
- `LogsLive` extraction: expanding a group lists all its original lines;
  "Show all like this" shows every line with the signature, including
  non-adjacent runs, and its chip removes the pattern; Copy/Download push
  a `logs-export` event whose text is the original `raw` lines in order.
- `LogsLive`: repeated lines show one row with `×N`; a new similar line
  bumps the count without adding a row; "Group repeats" off shows every
  line; typing in the filter field narrows the
  rows and updates "N of M lines"; new lines that don't match are not
  shown; `<mark>` highlighting; the no-match message and its Clear filter
  button; level filter combined with text; Pause/Resume count; Clear;
  Previous toggle only for kubectl.
- Nav and connection-bar tab lists include `/logs`.
