# Plugins: handoff to a new session

Start here. Tasks 1–7 are done, plus a fix round from the final review.
Left: the user's live riak_core test, and the open items under "Final
review findings". Nothing is committed in either repo.
Status as of 2026-10-26 (this machine: Elixir 1.18.4, OTP 28). beamdash:
536 tests, 0 failures, 1 excluded. Plugin project: 43 tests, 0 failures.

### Changes from the review rounds that later tasks must know

- `Beamdash.Plugins.list/1` statuses add `:building` (a startup build in a
  background task) and entries carry `build_error` (a startup build failed;
  the last good build is still loaded). `page/3` can return
  `{:error, :building}`.
- `plugins.json` entries store `"prefix"`; `rebuild`/`remove` are refused
  while a rebuild or startup build of that app runs.
- `Build.scan` refuses a plugin prefix whose namespace already has modules
  (e.g. `Beamdash`, `Mix`), and `Elixir`/`Beamdash`/`BeamdashWeb` outright.
- `Build.stop_compile/1` kills a dead caller's compiler workers via the
  Elixir-internal `:elixir_compiler_info` key (1.18: workers are
  `spawn_monitor`ed, not linked). If a future Elixir drops it, it no-ops.
- Open by choice: commit-call timeout can report a finished install as
  failed; Compat treats 4-part OTP vsns (`9.2.4.1`) as invalid; refresh
  results can arrive out of order; `:changed` is broadcast twice;
  install/startup/rebuild compiles can overlap.
- riak_core plugin: ring accessors run on the target in one rpc of
  `erl_eval:exprs/2` with fixed, compile-time-parsed expressions (reviewed
  as acceptable; the plan's "several rpcs passing the Ring back" wording is
  outdated). Pages load with `start_async`. Open minors: the plugin's test
  suite aborts if epmd/distribution can't start; page tests use LiveView
  internals; stale rows for one rpc after a filter change; Ring header says
  "every 5 s" though ring-ready is 30 s. Undecided: `optional: true` on the
  `riak_core_lite` dep.

## Read first

1. Spec: `docs/superpowers/specs/2026-10-24-plugins-design.md`
2. Plan: `docs/superpowers/plans/2026-10-25-plugins.md`. Global Constraints
   are at the top; Tasks 5–7 are still to do.
3. The progress ledger and task briefs that used to live in
   `.superpowers/sdd/` (`plug-progress.md`, `plug-task-4-brief.md`, `-5-`,
   `-6-`) are **gone**. Work from the plan's task sections instead.

## How the work is done

- Use superpowers:subagent-driven-development: one implementer agent per
  task, then a review agent, then a fix pass and re-review for Critical or
  Important findings. TDD in every task.
- **Never commit, push or publish**, in beamdash or the plugin repo, unless
  the user asks. The user has committed the rename and the earlier features
  (connection panel, Logs tab, settings persistence) themselves as `wip`
  (6aeea78). Task 4 and the 1.18 fixes are uncommitted on branch
  `add-logs-plugins`.
- Before reading code for a question, run `graphify query "<question>"`. Per
  `CLAUDE.md` it would be `.graphify-venv/bin/graphify`, but that venv doesn't
  exist here; use the `graphify` on PATH (`~/.local/bin/graphify`). Run `graphify update .` after code
  changes.
- Review diffs: the snapshot scripts (`snap.sh`, `rdiff.sh`) are gone. Diff
  against the `wip` commit instead: `git diff 6aeea78` plus
  `git status --short` for new untracked files. Before each task, note the
  current state (e.g. `git stash create` or copy the touched files) so the
  task's own diff can be isolated.
- The full suite passes: 481 tests, 0 failures (`mix test`, about 60 s).
- The user can't see subagent output: report results yourself, in plain
  terms.

## Elixir 1.18 / OTP 28 gotchas

The plan assumed Elixir 1.20. On this machine:

- Compiled regexes can't be escaped into code (module attributes,
  `unquote(Macro.escape(regex))`). Store source and options, or wrap them in
  a function. Fixed in `lib/beamdash/logs/group.ex` and
  `test/beamdash/plugin_api_test.exs`.
- Compiling leaves the new modules loaded. `Build.compile/3` now unloads
  them (`lib/beamdash/plugins/build.ex`), so only `load/2` loads code.

## Done (Tasks 1–4)

- `Beamdash.Plugins.Spec` (`lib/beamdash/plugins/spec.ex`): parses the
  Mix-dependency text without evaluating it.
- Plugin API:
  - `Beamdash.Plugin` (`lib/beamdash/plugin.ex`): `use Beamdash.Plugin,
    name:, pages:`, plus `rpc/5`, `app_running?/2`, `app_version/2` and
    `version/0`. `__current_node__/1` catches Target exits.
  - `Beamdash.Plugin.Page` (`lib/beamdash/plugin/page.ex`)
  - `Beamdash.Plugin.Format`
- Fixture plugin: `test/fixtures/plugins/hello_plugin/`. It declares
  `{:hello_app, "~> 1.0", runtime: false}` as its supported app.
- `Beamdash.Plugins.Fetch` (`lib/beamdash/plugins/fetch.ex`): Git, Hex or
  path.
- `Beamdash.Plugins.Build` (`lib/beamdash/plugins/build.ex`):
  `read_project`, `scan`, `compile`, `check`, `load`, `unload` and
  `safe_rm_rf`. Install order (differs from the plan's Task 3 text):
  - `scan` → `compile(src, ebin, scan_modules)` →
    `check(modules, prefix, ebin)` → `load(ebin, modules)`;
  - `compile/3` refuses any module the scan didn't predict;
  - `check/3` loads nothing;
  - a plugin ebin is never prepended to the code path.
- **Task 4** (uncommitted):
  - `Beamdash.Plugins` (`lib/beamdash/plugins.ex`): the registry GenServer,
    with `list`, `active`, `page`, `install`, `remove` and `rebuild`, plus
    startup and the active set.
  - `Beamdash.Plugins.Compat` (`lib/beamdash/plugins/compat.ex`).
  - Supervised in `application.ex` after `Beamdash.Logs`, with
    `Beamdash.Plugins.TaskSup` before it.
  - `:plugins_dir` is set to a temp dir in `config/config.exs` (test env),
    not `test_helper.exs`, because the app reads it at startup.
    `test_helper.exs` checks it's under the temp dir and removes it after
    the suite.
  - `test/beamdash/plugins_test.exs`: 18 tests, all pass; compiles with
    warnings as errors.
  - Reviewed and fixed over three rounds (see the top section).
  - Rebuild tests print a harmless "redefining module HelloPlugin" warning,
    and the defimpl test a harmless "protocol already consolidated" one.
- **Task 6** (no commits; `git init` only): the riak_core plugin at
  `/Users/dkliarov/projects/erl/beamdash-riak-core-plugin`, with ring,
  members, vnodes and handoffs pages, LICENSE (GPL-3.0), and the beamdash
  integration test `test/beamdash/riak_core_plugin_test.exs` (excluded by
  default; `mix test --only riak_core_plugin` passes). Not yet tried
  against a live riak_core node.

## To do

- **Task 5**: done and reviewed (one fix round). Settings → Plugins card
  (`lib/beamdash_web/plugins_settings.ex`), nav Plugins menu (`layouts.ex`),
  `PluginLive` (live_render only when connected; placeholder on the static
  render), `GET /plugins/:plugin/plugin.css` (`PluginAssetController`,
  refuses symlinks, `nosniff`). Registry additions: `css_path/2`, `dir/1`,
  `page/3` adds `module:`. Plugin events reach views only via the
  Connection hook (`plugins_changed/2`). Suite: 526 tests, 0 failures, 1
  excluded. Open: install progress is lost if the LiveView reconnects
  mid-install; the syntax-toggle remount of a plugin page and the nav JS
  are unverified in a browser (check in Task 7).
- **Task 6**: done (see Done). The user pushes the plugin repo to
  `git@github.com:dskliarov/beamdash-riak-core-plugin.git`. riak_core source
  for reference: https://github.com/riak-core-lite/riak_core_lite (newest
  tag `v0.11.0`; Hex has 0.11.1), cloned into the scratchpad, never a project.
- **Task 7**: done on 2026-10-25/26 except the live riak_core test (the user
  will do it). Format, compile -Werror and tests pass in both repos
  (beamdash 526/0/1 excluded, `--only riak_core_plugin` 1/0, plugin 43/0).
  Screenshots were taken (scratchpad, not kept); the riak Owner `<select>`
  was unstyled and is fixed in the plugin's `plugin.css`. Light-mode shots
  need `--blink-settings=preferredColorScheme=1` on a dark-mode Mac.
  `graphify update .` run.

## Final review findings

**Status (2026-10-26):** the user chose to fix Important 1, 2, 4 and the
minors a–g below; all are fixed (suite 536 tests, 0 failures, 1 excluded).
Hex releases: Hex ≥ 2.5 prints `Recent releases:` then one `  x.y.z (date)`
line each (`(retired)` after the date, colour codes); Hex ≤ 2.4 prints
`Releases: a, b (retired), ...` on one line — both parsed. Missing Hex now
fails fast ("Hex is not installed: run `mix local.hex`"). README and
docs/usage.md have Plugins sections. New: `Apps.running/1`
(`which_applications`), `Build.in_plugins_dir?/1` (path plugins inside the
plugins dir are refused). The spec/plan still describe only the per-line
Hex format and don't mention that refusal.
**Still open by choice:** Important 3 (deps rule), install-compile timeout,
Target resubscribe, a 1.15 CI run. **Flaky:** one full-suite run of ~15
had 1 failure that didn't recur; the failing test wasn't captured.

Original findings:

- **Important**
  1. Hex: `Fetch.parse_releases/1` (`fetch.ex:193-207`) expects one
     `  x.y.z (date)` line per release; real `mix hex.info` may print
     `Releases: 1.4.4, 1.4.3, …` on one line. Unverified (no Hex archive
     here). Exact versions skip it. Check real output, parse both.
  2. Hex not installed: `mix hex.*` prompts "Shall I install Hex? [Yn]" and
     the install hangs 120 s, then says "mix timed out". Detect and fail
     fast with "run `mix local.hex`".
  3. Deps (spec-mandated behaviour): `only: :test` deps without
     `runtime: false` (lazy_html, floki, mox) make a plugin uninstallable;
     `{:ex_doc, …, only: :dev, runtime: false}` shows as a supported app.
     Spec change needed.
  4. No user docs: README and docs/usage.md don't mention plugins.
- **Minor**: Settings warning says "fetching it runs its mix.exs" (false;
  compiling runs plugin code); a `path:` inside the plugins dir can be
  deleted by commit/remove; `check/3` doesn't validate page shapes from a
  hand-written `__beamdash_plugin__/0` (bad label crashes the nav); slug
  regex in `plugin.ex:62` uses `^…$` not `\A…\z`; `Compat.reason/1` unused,
  `"v0.11.0"` vsns invalid; `app_running?/2`/`app_version/2` use
  `Apps.list/1` (no library apps) vs the registry's `which_applications`;
  protocol impls in plugins don't take effect (consolidated) — document;
  no overall install-compile timeout; registry subscribes to Target once;
  `mix.exs` read with `File.stat` (follows symlinks; use `lstat`).
- Screenshot nits: Settings cards touch (pre-existing CSS); long paths
  wrap mid-word; path plugin path shown twice.
- 1.15–1.17 never actually run; one CI run on 1.15 before claiming 1.15+.

## Open minor follow-ups (for the final review)

- `Spec`: `emit_warnings: false` needs Elixir 1.16. On 1.15 it is ignored
  and only causes a stderr warning.
- `Build` on Elixir 1.15/1.16: it's unverified whether compile loads a
  clashing module eagerly. On 1.18 it does leave compiled modules loaded
  (handled, see above).
- `Build`: `loaded_since` could purge an unrelated in-memory module loaded
  during a failed compile (a small window).
- `Fetch`: `mkdir` and `chmod` are two steps, a brief window for
  `default_hex_cmd/2` under the shared temp dir. With no `kill` executable
  on the system, the timeout path can't close the port.
- The scan is best-effort by design. `apply/3`, `Code.eval_*` and atom-module
  calls pass it, and `compile/3` catches any that compile a module.
- graphify: two `.erl` files add nothing to the graph until
  `pip install "graphifyy[erlang]"` is installed in its venv.

## Handy

- The Chrome binary for screenshots is
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` (present),
  run with `--headless=new --force-dark-mode`.
- To render a LiveView to HTML without `lazy_html`, follow
  `test/beamdash/logs_live_test.exs`: a throwaway test that writes
  `/tmp/*.html`. Delete it afterwards.
