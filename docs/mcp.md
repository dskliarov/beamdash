# Using beamdash from an AI assistant

beamdash exposes the node it is attached to over MCP, so a coding agent can
read its processes, applications, logs and crashes. The `erlang-triage` skill
in `skills/erlang-triage/` tells the agent how to use those tools to find
bottlenecks, read the code behind them and recommend fixes.

Everything the tools return is read-only. The agent cannot start, stop or
change anything on the node.

## Contents

- [Requirements](#requirements)
- [Set up the MCP server](#set-up-the-mcp-server)
- [Install the skill](#install-the-skill)
- [Tools](#tools)
- [Publish a report](#publish-a-report)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)

## Requirements

- beamdash running (`mix phx.server`) and attached to a node. See
  [Start and connect](usage.md#start-and-connect).
- Claude Code, or Claude Desktop, on the same machine as beamdash.
  The endpoint only accepts loopback clients, so a cloud assistant cannot
  reach it directly (see [ChatGPT](#chatgpt)).

## Set up the MCP server

The endpoint is `http://127.0.0.1:4000/mcp`. Check it first:

```sh
python3 examples/mcp_client.py
```

This lists the tools and calls `node_info`. If beamdash is not attached to a
node, the call says so. Connect the node in beamdash and run it again.

### Claude Code

```sh
claude mcp add --transport http beamdash http://127.0.0.1:4000/mcp
```

Run `/mcp` inside Claude Code to confirm `beamdash` is connected and lists
fifteen tools.

### Claude Desktop

Claude Desktop reaches local servers through a small bridge. Add this to
`claude_desktop_config.json` (Settings > Developer > Edit Config) and restart
Claude Desktop:

```json
{
  "mcpServers": {
    "beamdash": {
      "command": "npx",
      "args": ["mcp-remote", "http://127.0.0.1:4000/mcp"]
    }
  }
}
```

Requires Node.js, so `npx` is available.

### ChatGPT

ChatGPT connects to MCP servers over public HTTPS. beamdash only accepts
loopback requests on purpose, so a tunnel is not a good option: it would give
a cloud service read access to your node's processes, logs and crash stacks.
Until that changes, use ChatGPT with pasted output (see
[Examples](#examples), example 4).

## Install the skill

The skill is a folder with a `SKILL.md`. Claude Code reads skills from
`~/.claude/skills/` (every project) or from `.claude/skills/` in a project.

Install it for all your projects with a symlink, so updates in the repo
apply to it too:

```sh
mkdir -p ~/.claude/skills
ln -s "$PWD/skills/erlang-triage" ~/.claude/skills/erlang-triage
```

Run this from the beamdash repository root. To install it for one project
only, copy the folder into that project's `.claude/skills/` instead.

Start a new Claude Code session, then check that `erlang-triage` is listed
(type `/` and look for it, or ask "what skills do you have?").

## Tools

All tools need beamdash connected to a node. Names for `app`, `module` and
`pid` must come from another tool's output (for example `app_list`).

| Tool | Arguments | What it returns |
| --- | --- | --- |
| `node_info` | none | Node name, OTP and ERTS versions, process count, memory, schedulers, uptime |
| `list_processes` | `limit` (default 100, max 1000) | Processes, largest memory first, each with a `pid` |
| `process_details` | `pid`, e.g. `<0.123.0>` | Memory, GC, reductions, mailbox length (not the messages) |
| `ets_tables` | none | ETS tables, largest memory first, with owner and size |
| `app_list` | none | Running applications: name, description, version, master |
| `app_info` | `app` | One application's version, start type, folder, environment, `needed_by` |
| `app_tree` | `app` | The application's process tree, from its application master |
| `module_summary` | `module`, e.g. `lists` or `Beamdash.Mcp` | File, version, behaviours, exports, owning application, source availability; `source` is the path it was compiled from, and `local_file` the source file on this computer when a source folder has it |
| `crashes` | `limit` (default 100, max 1000) | Recent crash reports, newest first: process, initial call, class, reason, stack |
| `logs` | `limit`, optional `level` (e.g. `error`) | Recent log lines, newest first: time, level, process, location, message |
| `snapshots` | `window` in minutes (default 60, max 10080), optional `reason` (`load`, `memory`, `heap_rising`) and `pid`, `limit` | Process snapshots stored for the node, newest first: time, pid, reason, process data |
| `anomaly_history` | `window` in minutes (default 60, max 10080), optional `measure` and `pid`, `limit` | Anomaly episodes stored for the node, newest first: start time, pid, measure, duration, text |
| `memory_history` | `window` in minutes (default 1440, max 10080), optional `table`, `limit` (default 500, max 1000) | Memory samples stored for the node, newest first: time, memory, atom and ETS table counts; with `table`, that table's type, size, memory and owner at each sample (`null` when it was not among the largest then) |
| `ets_rows` | `table` (name from `ets_tables`), optional `limit` (default 10, max 20) | Up to `limit` rows of one ETS table, read within one second: `rows` as text, `keypos`, and `stop` (`complete`, `rows` or `time`) |
| `source_check` | `app` | Whether the application's source folder is the code the node runs: `status` (`match`, `mismatch`, `dirty`, `no_ref`, `no_git`, `git_error` or `no_folder`), the commit in its version, the folder's HEAD, and `changed` (uncommitted files) |

`crashes` and `logs` only contain what beamdash has collected since it
connected to the node. Logs are kept for the last 2,000 entries and crash
reports for the last 500.

`snapshots` and `anomaly_history` read what beamdash stored while snapshot
collection was on in its settings. Snapshots are kept for 7 days and anomaly
episodes for 30 days. While collection is off, or the event store is not
running, both tools return an error instead of rows.

`memory_history` reads the memory samples beamdash stored, so it needs
snapshot collection on, like `snapshots`. `ets_rows` reads the live node, and
its rows are terms shown as text, so keep the limit small. `source_check`
compares the version the node runs with the git checkout beamdash has for
that application in its source folders (`source_dirs`); a folder must be
configured for it to find one.

Plugins can add tools. A plugin that declares `mcp_tools:` offers each one as `<app>.<name>`, for example `riak_core.ring`, only while its application runs on the attached node. A tool that raises, returns something other than `{:ok, data}` or `{:error, message}`, or takes longer than 5 seconds is reported as an error to the assistant; beamdash keeps running.

## Publish a report

The tools above only read. The one write is a report from an agent, such as
the `erlang-triage` skill after an analysis, which beamdash stores for the
attached node. It does not depend on snapshot collection.

1. Open Settings and add a client under **Report clients**, for example
   `laptop`. beamdash shows its token once. Copy it then: only a SHA-256 hash
   is kept, so a lost token cannot be shown again. Create a new client instead.
2. Revoke the client in the same place to stop its token at once.

Send the report to `POST http://127.0.0.1:4000/reports` with the token as a
bearer token and a JSON body:

```sh
curl -s http://127.0.0.1:4000/reports \
  -H "authorization: Bearer $BEAMDASH_REPORT_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"run_id":"2026-11-09-1430","subject":"triage","verdict":"needs_attention",
       "summary":"Mailbox backlog in orders_worker.",
       "findings":[{"severity":"high","type":"bottleneck","title":"Mailbox backlog",
                    "evidence":"<0.512.0> has 48,310 messages",
                    "verdict":"Orders.Worker calls the payment API synchronously.",
                    "source":"lib/orders/worker.ex:88","fix":"Move the call into a Task.",
                    "verify":"Watch the mailbox length of <0.512.0>."}],
       "healthy":["No crash loops."],"not_checked":["No load test."]}'
```

| Field | Rules |
| --- | --- |
| `run_id` | Required, up to 100 bytes. A client that sends the same `run_id` again within 24 hours gets the first report back and nothing is stored twice. |
| `subject` | Required: `triage` or `app:<name>`, where `<name>` is letters, digits, `_` or `.`. |
| `verdict` | Required: `healthy`, `needs_attention` or `critical`. |
| `summary` | Optional text, up to 2,000 bytes. |
| `findings` | Optional list of up to 50 items. Each needs `severity` (`high`, `medium`, `low`), `type` (`bottleneck`, `error`, `caveat`), `title`, `evidence` and `verdict` (the cause), up to 2,000 bytes each for the text fields and 200 for `title`. `source` (up to 300 bytes), `fix` and `verify` are optional. |
| `healthy`, `not_checked` | Optional lists of up to 50 lines, each up to 300 bytes. |

Responses:

| Status | Meaning |
| --- | --- |
| 201 | Stored. The body has `run_id` and `status: "stored"`. |
| 200 | Already stored within 24 hours. |
| 401 | No token, a wrong token, or a revoked one. |
| 403 | The request did not come from loopback. |
| 405 | Not a POST. |
| 409 | beamdash is not connected to a node. Nothing is stored. |
| 413 | The body is over 256 KB. |
| 422 | The report is invalid. The `error` text says which field. |
| 503 | The event store is not running. Nothing is stored. |

Reports are kept for 90 days, up to 10,000 of them.

## Examples

The outputs below are illustrative, to show their shape. Your node will have
different processes and numbers.

### 1. Ask for a full analysis

In Claude Code, in any project:

> Use the erlang-triage skill to analyze the connected node. Focus on
> anything that looks like a bottleneck.

The skill makes these calls in order: `node_info`, `list_processes` (20),
`process_details` for the top ones, `ets_tables`, `app_list`, then
`app_info`/`app_tree` for applications the findings touch, `crashes`,
`logs` (errors), `module_summary` and the source code for each finding. It ends
with a ranked report:

```
1. Mailbox backlog in orders_worker (high)
   Evidence: <0.512.0>, mailbox 48,310 messages, reductions 2.1x the median.
   Cause: Orders.Worker.handle_info/2 (lib/orders/worker.ex:88) calls the
   payment API synchronously, so messages queue behind each call.
   Fix: move the call into a Task, or use a pool, and confirm by watching
   the mailbox length of <0.512.0> over two samples.

2. ETS table cache_items grows by about 20 MB per minute (medium)
   Evidence: 1.4 GB in ets_tables, owner <0.300.0>, no eviction in the module.
   ...
   Not verified: the table's TTL setting, which is not visible from here.
```

### 2. Investigate a crash

> The node logged a crash in the last hour. Find the cause.

The skill calls `crashes` (limit 50), groups by `reason` and `initial_call`,
then `logs` with `level: "error"` around the first report, and finally
`module_summary` and the source of the module in the stack.

You can also make the calls yourself:

> Call crashes with limit 5 and show me the top reason.

### 3. Check one application

> Show the process tree of kernel and tell me which processes have large
> mailboxes.

This uses `app_tree` and then `process_details` on the matching pids.

### 4. Use ChatGPT with pasted output

Save the output of a call with the helper script, then paste it into ChatGPT
together with the skill text:

```sh
python3 examples/mcp_client.py list_processes '{"limit": 20}' > processes.json
python3 examples/mcp_client.py crashes '{"limit": 50}' > crashes.json
```

Paste `skills/erlang-triage/SKILL.md` as the instructions, then the two files,
and ask for the same report.

### Call the tools directly

`examples/mcp_client.py` takes a tool name and JSON arguments:

```sh
python3 examples/mcp_client.py app_list
python3 examples/mcp_client.py app_tree '{"app": "kernel"}'
python3 examples/mcp_client.py module_summary '{"module": "lists"}'
python3 examples/mcp_client.py logs '{"level": "error", "limit": 20}'
```

Or with `curl`, using the protocol directly:

```sh
curl -s http://127.0.0.1:4000/mcp \
  -H 'content-type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"list_processes","arguments":{"limit":5}}}'
```

## Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `beamdash is not connected to a node` | Attach beamdash to a node first (the Connection panel). |
| `the node did not answer: ...` | The node is busy or unreachable. Raise the node call timeout in Settings if it is slow. |
| `no application named X is known` | Use a name from `app_list`. The name must already exist on the node. |
| `X is not on the node` | The application is not running on the node, so `app_info` or `app_tree` has nothing to show. |
| `X is not loaded on the node` | `module_summary` only describes modules loaded on the node. |
| HTTP 403 | The request came from a non-loopback address or with a foreign `Host` or `Origin`. Use `127.0.0.1` or `localhost`. |
| HTTP 400, `Unsupported MCP-Protocol-Version` | The client speaks a different protocol version. Update the client, or send `MCP-Protocol-Version: 2025-06-18`. |
| HTTP 401 on `/reports` | The token is missing, wrong or revoked. Check `BEAMDASH_REPORT_TOKEN`, or create a new client in Settings. |
| HTTP 409 on `/reports`, `beamdash is not connected to a node` | Attach beamdash to a node, then send the report again. |
| HTTP 503 on `/reports` | The event store is not running. It is off when `store_file` is `false` in the config. Turn it on, then send the report again. |
| The skill does not appear in Claude Code | Check the symlink (`ls -l ~/.claude/skills/erlang-triage`) and start a new session. |

## Privacy

The tools send process state, log lines and crash stacks to the assistant
you use. Those can contain request data, identifiers or secrets that your
application logs. Check what your logs contain before you analyze a
production node with a hosted model, and prefer a staging node when you can.
