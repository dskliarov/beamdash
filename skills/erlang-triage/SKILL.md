---
name: erlang-triage
description: Diagnose a connected BEAM node through the beamdash MCP tools. Triages a symptom on the node, or runs a full analysis of one application (bottlenecks, errors, caveats) and reads its source to give a verdict with proposed changes. Use when asked to analyze, troubleshoot or review an Erlang or Elixir node or application.
---

# Erlang triage with beamdash

The beamdash MCP tools read the node beamdash is attached to. Every tool is read-only.
If a tool says beamdash is not connected, ask the user to connect it in beamdash first.

`snapshots`, `anomaly_history` and `memory_history` read stored history, not the live node. They return an error while snapshot collection is off in beamdash's settings, or while its event store is not running. If that happens, ask the user to turn collection on and let it run for a while, then continue without the history steps and list them under limits.

`ets_rows` reads the live node: up to 20 rows of one table, within one second. Keep its limit small (5 to 10), and treat the rows as evidence of what is stored, not as a full dump.

`source_check` compares an application's version (its commit) with the git checkout beamdash has for it. Use its `status`: `match` means the source is the code the node runs; `mismatch` or `no_ref` means the code may differ from what runs, so say so in every finding that cites source; `dirty` means the checkout has `changed` uncommitted files, so the source may differ from the commit the node runs; `no_folder` means no source folder is configured for the app, so use the source path search below; `no_git` means the folder is not a git checkout; `git_error` means it is at the built commit but git could not list its changes, so treat it like `dirty` and say so.

## Choose a mode

- **Triage** for a symptom or the whole node ("the node is slow", "why did it crash"). Follow the triage steps.
- **Analyze the app** for one application ("analyze pace_keeper_core"). Follow the app analysis steps. It covers all of the app's runtime data and its source code, and ends with a verdict and proposed changes.

If the user does not name an application for an app analysis, call `app_list` and ask which one to analyze.

## Before you start

**Source path.** Find it before asking. If the user already gave a path in this conversation, reuse it. Otherwise take a module of the application (the `initial_call` module of one of its processes, or any module from `app_tree`) and call `module_summary`. When beamdash has a local copy of the module, the summary's `local_file` is its path on this computer. Walk up from `local_file` to the nearest folder that contains `mix.exs` or `rebar.config`; for an umbrella, that is the folder above `apps/`. That folder is the source path. `source` is where the node compiled the module, which may not exist on this computer, so use it only as a hint.
If no module of the application has a `local_file`, search the project folder. Use the project folder the user gave in this conversation if there is one. If not, ask the user for it once, as an absolute path such as `~/projects`. If `source_check` returns a `folder` for the application, offer it as the default in that question. Search the project folder recursively for the application's project, and include its `deps` folder, because a dependency's source is there. Skip only `_build` and `node_modules`:

```sh
grep -rl --include=mix.exs --include='*.app.src' --include=rebar.config \
  --exclude-dir=_build --exclude-dir=node_modules \
  -E "app: :<app>|\{application, <app>" "<folder>"
```

Replace `<app>` with the application name and `<folder>` with the project folder. Each match's folder is a candidate source path: for an umbrella, the match is `apps/<app>/mix.exs`, so use the folder above `apps/`. A match under `deps/` of a project is a dependency copy: prefer the project that depends on it, and say so in the report. Use one match without asking. If there are several, ask which one. If there are none, ask the user for the repository root (for example `~/projects/my_app`); check that it contains `mix.exs` or `rebar.config`, and reuse it. Do not search outside the project folder. If the user has no source to give, continue with runtime analysis only and mark every code-level finding as unverified.

## Triage steps

1. **Node overview.** Call `node_info`. Note process count, memory split, scheduler count and uptime.

2. **Processes.** Call `list_processes` with `limit` 20. For the top processes, call `process_details` with their pid.
   Flag:
   - mailbox length over 1000 (a consumer that cannot keep up),
   - memory over 100 MB,
   - reductions far above the rest (a busy loop or hot path),
   - many garbage collections with little memory freed.

3. **ETS.** Call `ets_tables`. Flag tables over 50 MB, tables that grow with each step, and tables with an owner that should not own large data. For a flagged table, call `ets_rows` with its name and `limit` 10 to see what it holds (keys and values). If its `stop` is `time`, the rows are a partial read: say so. Then `memory_history` with `table` set to its name to see whether it grows over time.

4. **Applications.** Call `app_list` to see what runs. For each application that the findings touch, call `app_info` (start type, needed_by) and `app_tree` (its process tree).
   Flag:
   - a process with a large mailbox or memory inside an application tree,
   - a tree whose `count` is far larger than the number of workers it should have,
   - a non-permanent application that is not running when it should be.

5. **Crashes.** Call `crashes` with `limit` 50. Group by `initial_call` and `reason`. A repeated reason is more important than a single crash.

6. **Logs.** Call `logs` with `level` "error" and `limit` 200. Then call `logs` without a level filter for the time around the first error. Group repeated messages and note their first and last times.

7. **History.** Call `anomaly_history` with `window` 1440 (one day, or up to 10080 for an older symptom) and `limit` 200. Group the episodes by `pid` and `measure`. A pid with many episodes, or a long `duration_ms`, is a finding; `data.text` says what beamdash saw. Then call `snapshots` with the same window, grouped by `pid` and `reason`. A pid that shows up in many snapshots is a candidate for the processes above, and its `process` data shows memory and mailbox at the time. Compare the first and last times with the symptom. Call `memory_history` with the same window for the node's memory and ETS table count: a steady rise across the window is a finding even when no single process stands out.

8. **Code.** Call `source_check` for each application a finding touches before reading its source, and apply the `status` rules above. For each finding, find the module:
   - a process's module is its `initial_call` module, or for a supervisor, its callback module (`process_details` gives `initial_call`),
   - a crash or log line names a module in its `where` or `stack`.
   Call `module_summary` for that module. Read its source starting at the function in the stack or log line: from `local_file` when the summary has one, else under the source path, matching the module's `application` to the app's folder there. If neither has the module, say so and do not guess its code.

8. **Report.** Give a short ranked list. For each finding:
   - the evidence: pid, application, module, counts, the exact error text, and the time,
   - the likely cause in code, as `file:line` where you can find it,
   - the smallest fix, and how to confirm it on the node.
   Say what you could not verify, for example if a log is missing, history was off, or the source is not under the source path.

## Analyze the app steps

Goal: find bottlenecks, errors and caveats in one application, read the code behind each one, and give a verdict with proposed source changes. Do not edit the source files unless the user asks. Show every change as a diff.

1. **App metadata.** Call `app_list` to confirm the app runs. Call `app_info` for it and note `vsn`, `start_type`, `applications` (its dependencies) and `needed_by`. Call `source_check` for the app and report its `status`, `ref` and `head`. If the status is not `match`, the code may not match what runs, so say so in the report, and give the count in `changed` when `dirty`.

2. **Process tree.** Call `app_tree`. Note `count` and the shape. Flag a single process with many direct children (a serialization point), and a tree size far from what the source starts. Each process in `procs` may carry `mailbox` and `reductions` when the node's agent reports them; use those as the first sample. For every pid in the tree, call `process_details`. Record memory, mailbox length, reductions, GC counts, `initial_call` and `current_function`.

3. **Two samples.** Repeat `process_details` for the tree's pids a few seconds apart, and `list_processes` for node totals. Compare mailbox length, memory and reductions between the samples. A growing mailbox or memory is a finding. A high value that is stable is not, on its own.

4. **ETS.** Call `ets_tables`. Keep tables whose `owner` is a pid in the tree, or whose name starts with the app's module prefix (for example `Elixir.PaceKeeperCore.`). Flag tables over 50 MB, and tables that grow between samples.

5. **Crashes, logs and history.** Call `crashes` with `limit` 500 and keep the reports whose `process`, `initial_call` or `stack` belongs to the app's modules. Call `logs` with `level` "error" and `limit` 200, and `logs` with no level and `limit` 200. Keep lines whose `where` module belongs to the app. Group by message, and note the count, first time and last time. A restart loop (the same `initial_call` crashing repeatedly) ranks above a single crash.
   Then call `anomaly_history` and `snapshots` with `window` 10080 and `limit` 1000, and keep rows whose `pid` is in the app's tree. For each ETS table the app owns (from step 4), call `memory_history` with `window` 10080 and that table's name, and note the trend of its `table.memory` across the samples. For each pid, note how many episodes or snapshots it has, which `measure` or `reason` recurs, and whether the episodes stretch over time (a pattern across days is stronger than a burst). Use the snapshot `process` data (memory, mailbox length) as evidence, and say when a pid has no history.

6. **Caveats.** From `app_info` and `app_list`, check that the app is running as `permanent` when it should be, that every application in `applications` is running, and what depends on it through `needed_by`. Compare `start_type` with what the source expects.

7. **Source.** For each finding, get the module (from `initial_call`, the crash `stack`, or the log `where`), call `module_summary`, then read it from `local_file` or under the source path. Read the function that holds the behavior and its callers. Look for:
   - blocking work (HTTP, database, file, `Process.sleep`) inside `handle_call` or `handle_info`, or synchronous `GenServer.call` with the default 5 s timeout,
   - one process serializing work for many workers,
   - unbounded growth: maps, lists, ETS tables or buffers that are only added to,
   - missing `timeout`s, or no handling of `:timeout` and `:exit`,
   - supervisor restart intensity too low for a flaky child, or a `:temporary` child that should be `:permanent`,
   - a `:public` ETS table with many writers, or no size limit or TTL.
   Cite `file:line` for each.

8. **Verdict.** Start with one overall verdict: **Healthy**, **Needs attention**, or **Critical**. Then list the findings, most severe first. For each one give:
   - **Type:** bottleneck, error, or caveat.
   - **Severity:** high, medium or low, with the reason.
   - **Evidence:** pids, counts and changes between samples, the exact error text, and times.
   - **Source:** `file:line` and what the code does there.
   - **Verdict:** the cause, in one or two sentences.
   - **Proposed change:** a minimal unified diff against the source path, in a code block.
   - **Verify:** the test to add, and what to watch on the node after the change.
   List healthy checks in one line each.

9. **Limits.** State what was not checked: a running version that differs from the source (a `local_file` is the copy on this computer, which may not be the version the node runs), errors, crashes and logs older than what beamdash collected (it only keeps what it saw since it connected), history older than the window or from a period when snapshot collection was off (snapshots are kept 7 days, anomaly episodes 30 days), no load test, and any module with neither a `local_file` nor a file under the source path.

## Publish the report

After the report is final, offer to save it in beamdash so it is kept with the node's data. Saving writes to beamdash's own store and does not change the node. Never post a report without the user's explicit yes for that report.

1. If `BEAMDASH_REPORT_TOKEN` is not set (check with `[ -n "$BEAMDASH_REPORT_TOKEN" ]`, without printing it), do not offer to post. Say in the report that it was not saved, and that the user can add a client under Settings > Report clients and export its token as `BEAMDASH_REPORT_TOKEN`.

2. Write a JSON body to a temporary file with the Write tool, built from the report:
   - `run_id`: unique for this run, for example the UTC time plus a short random suffix. Under 100 bytes.
   - `subject`: `triage`, or `app:<application>` for an app analysis.
   - `verdict`: `healthy`, `needs_attention` or `critical`, as in the verdict.
   - `summary`: one or two sentences.
   - `findings`: one object per finding, in ranked order, each with `severity` (`high`, `medium`, `low`), `type` (`bottleneck`, `error`, `caveat`), `title`, `evidence`, `verdict` (the cause), and optionally `source` (`file:line`), `fix` and `verify`.
   - `healthy`: the healthy checks, one line each.
   - `not_checked`: the items from the Limits step, one line each.
   Limits: text fields up to 2,000 bytes (`title` 200, lines and `source` 300), at most 50 findings and 50 lines per list. Shorten anything longer.

3. Ask before posting. Do not send in this step. Show the user, in plain text at the end of the report:
   - the destination: `http://127.0.0.1:4000/reports` (port 4000 unless `PORT` is set),
   - the `subject`, `verdict`, `run_id`, and the number of findings by severity,
   - the path of the body file, so they can read everything that would be sent,

   then ask: "Post this report to beamdash? (yes/no)" and stop. Wait for their reply.
   An earlier request such as "analyze the node" or "publish the report" is not a yes. Each POST needs its own yes, including a re-send after an error. If the answer is no, or there is no answer, do not post. Say the report was not posted and where the body file is.

4. Only after a yes, send it:

```sh
curl -s -o /tmp/beamdash-report-response.json -w '%{http_code}' http://127.0.0.1:4000/reports \
  -H "authorization: Bearer $BEAMDASH_REPORT_TOKEN" \
  -H 'content-type: application/json' \
  --data-binary @/tmp/beamdash-report.json
```

   The port is 4000 unless beamdash runs with `PORT` set.

5. Handle the status code:
   - **201**: saved. Give the `run_id` in the final reply.
   - **200**: already saved within 24 hours. Nothing new was stored.
   - **401**: the token is wrong or revoked. Tell the user to check `BEAMDASH_REPORT_TOKEN`. Do not retry.
   - **409** or **503**: beamdash is not connected to a node, or its event store is not running. Tell the user to fix that. Once they say it is fixed, ask again before sending the same body. A repeated `run_id` is safe.
   - **422**: the body is invalid, and the `error` text names the field. Fix that field, then ask again before sending.
   - **413**: the body is too large. Shorten the text, then ask again before sending.
   - Connection refused: beamdash is not running. Say so.

6. End the final reply with whether the report was saved and its `run_id`, or why it was not.

## Notes

- Thresholds are starting points. Compare against what the node normally does before calling something a problem.
- A process that is busy now may be healthy. Look at two samples a few seconds apart before concluding.
- `list_processes`, `crashes`, `logs`, `snapshots`, `anomaly_history` and `memory_history` return the newest or largest items first. `memory_history` sets `truncated` when it had more samples than its limit. An issue that started earlier may not appear there unless you widen the window or raise the limit, so state that limit in the report.
- Do not change anything on the node. These tools cannot do that, and the fixes belong in code.
