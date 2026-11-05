---
name: erlang-triage
description: Diagnose a connected BEAM node through the beamdash MCP tools. Triages a symptom on the node, or runs a full analysis of one application (bottlenecks, errors, caveats) and reads its source to give a verdict with proposed changes. Use when asked to analyze, troubleshoot or review an Erlang or Elixir node or application.
---

# Erlang triage with beamdash

The beamdash MCP tools read the node beamdash is attached to. Every tool is read-only.
If a tool says beamdash is not connected, ask the user to connect it in beamdash first.

## Choose a mode

- **Triage** for a symptom or the whole node ("the node is slow", "why did it crash"). Follow the triage steps.
- **Analyze the app** for one application ("analyze pace_keeper_core"). Follow the app analysis steps. It covers all of the app's runtime data and its source code, and ends with a verdict and proposed changes.

If the user does not name an application for an app analysis, call `app_list` and ask which one to analyze.

## Before you start

**Source path.** Ask the user for the path to the source code of the application being analyzed (the repository root, for example `~/projects/my_app`). If the user already gave it in this conversation, reuse it. Check that the path exists and contains `mix.exs` or `rebar.config`. If the user has no source to give, continue with runtime analysis only and mark every code-level finding as unverified.

## Triage steps

1. **Node overview.** Call `node_info`. Note process count, memory split, scheduler count and uptime.

2. **Processes.** Call `list_processes` with `limit` 20. For the top processes, call `process_details` with their pid.
   Flag:
   - mailbox length over 1000 (a consumer that cannot keep up),
   - memory over 100 MB,
   - reductions far above the rest (a busy loop or hot path),
   - many garbage collections with little memory freed.

3. **ETS.** Call `ets_tables`. Flag tables over 50 MB, tables that grow with each step, and tables with an owner that should not own large data.

4. **Applications.** Call `app_list` to see what runs. For each application that the findings touch, call `app_info` (start type, needed_by) and `app_tree` (its process tree).
   Flag:
   - a process with a large mailbox or memory inside an application tree,
   - a tree whose `count` is far larger than the number of workers it should have,
   - a non-permanent application that is not running when it should be.

5. **Crashes.** Call `crashes` with `limit` 50. Group by `initial_call` and `reason`. A repeated reason is more important than a single crash.

6. **Logs.** Call `logs` with `level` "error" and `limit` 200. Then call `logs` without a level filter for the time around the first error. Group repeated messages and note their first and last times.

7. **Code.** For each finding, find the module:
   - a process's module is its `initial_call` module, or for a supervisor, its callback module (`process_details` gives `initial_call`),
   - a crash or log line names a module in its `where` or `stack`.
   Call `module_summary` for that module. Then read its source under the source path, starting at the function in the stack or log line. Match the module's `application` to the app's folder under that path. If the module is not in that path, say so and do not guess its code.

8. **Report.** Give a short ranked list. For each finding:
   - the evidence: pid, application, module, counts, the exact error text, and the time,
   - the likely cause in code, as `file:line` where you can find it,
   - the smallest fix, and how to confirm it on the node.
   Say what you could not verify, for example if a log is missing or the source is not under the source path.

## Analyze the app steps

Goal: find bottlenecks, errors and caveats in one application, read the code behind each one, and give a verdict with proposed source changes. Do not edit the source files unless the user asks. Show every change as a diff.

1. **App metadata.** Call `app_list` to confirm the app runs. Call `app_info` for it and note `vsn`, `start_type`, `applications` (its dependencies) and `needed_by`. Compare the version with the source's `mix.exs` or `.app.src`. If they differ, the code may not match what runs, so say so in the report.

2. **Process tree.** Call `app_tree`. Note `count` and the shape. Flag a single process with many direct children (a serialization point), and a tree size far from what the source starts. For every pid in the tree, call `process_details`. Record memory, mailbox length, reductions, GC counts, `initial_call` and `current_function`.

3. **Two samples.** Repeat `process_details` for the tree's pids a few seconds apart, and `list_processes` for node totals. Compare mailbox length, memory and reductions between the samples. A growing mailbox or memory is a finding. A high value that is stable is not, on its own.

4. **ETS.** Call `ets_tables`. Keep tables whose `owner` is a pid in the tree, or whose name starts with the app's module prefix (for example `Elixir.PaceKeeperCore.`). Flag tables over 50 MB, and tables that grow between samples.

5. **Crashes and logs.** Call `crashes` with `limit` 500 and keep the reports whose `process`, `initial_call` or `stack` belongs to the app's modules. Call `logs` with `level` "error" and `limit` 200, and `logs` with no level and `limit` 200. Keep lines whose `where` module belongs to the app. Group by message, and note the count, first time and last time. A restart loop (the same `initial_call` crashing repeatedly) ranks above a single crash.

6. **Caveats.** From `app_info` and `app_list`, check that the app is running as `permanent` when it should be, that every application in `applications` is running, and what depends on it through `needed_by`. Compare `start_type` with what the source expects.

7. **Source.** For each finding, get the module (from `initial_call`, the crash `stack`, or the log `where`), call `module_summary`, then read it under the source path. Read the function that holds the behavior and its callers. Look for:
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

9. **Limits.** State what was not checked: a running version that differs from the source, errors or crashes older than what beamdash collected (it only keeps what it saw since it connected), no load test, and any module outside the source path.

## Notes

- Thresholds are starting points. Compare against what the node normally does before calling something a problem.
- A process that is busy now may be healthy. Look at two samples a few seconds apart before concluding.
- `list_processes`, `crashes` and `logs` return the newest or largest items first. An issue that started earlier may not appear there, so state that limit in the report.
- Do not change anything on the node. These tools cannot do that, and the fixes belong in code.
