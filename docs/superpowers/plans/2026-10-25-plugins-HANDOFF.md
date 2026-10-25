# Plugins: handoff to a new session

Start here. The previous session finished Tasks 1–3. A safety check there
began blocking every code-writing agent, so the rest moves to a new session.

## Read first

1. Spec: `docs/superpowers/specs/2026-10-24-plugins-design.md`
2. Plan: `docs/superpowers/plans/2026-10-25-plugins.md`. Global Constraints
   are at the top; Tasks 4–7 are still to do.
3. Progress ledger: `.superpowers/sdd/plug-progress.md`
4. Task briefs: `.superpowers/sdd/plug-task-4-brief.md`, `-5-`, `-6-`.
   Task 7 has no brief; it is the plan's last section.

## How the work is done

- Use superpowers:subagent-driven-development: one implementer agent per
  task, then a review agent, then a fix pass and re-review for Critical or
  Important findings. TDD in every task.
- **Never commit, push or publish**, in beamdash or the plugin repo. The
  beamdash working tree holds the user's uncommitted exberly→beamdash
  rename and the earlier features (connection panel, Logs tab, settings
  persistence). Leave everything uncommitted.
- Before reading code for a question, run `graphify query "<question>"`. It is
  on PATH, not in `.graphify-venv`. Run `graphify update .` after code changes.
- Review diffs: there are no commits, so diff the working tree against a
  snapshot.
  - `.superpowers/sdd/snap.sh <name>` copies lib, test, src and priv to
    `.superpowers/sdd/lsnap-<name>`.
  - `.superpowers/sdd/rdiff.sh <name> <out>` writes the diff.
  - Take a snapshot before each task.
- The full suite passes, 463 tests (`mix test`, about 60 s).
- The user can't see subagent output: report results yourself, in plain
  terms.

## Done (Tasks 1–3)

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
  `safe_rm_rf`.
- **Interface change for Task 4** (it differs from the plan's Task 3 text):
  - the install order is `scan` → `compile(src, ebin, scan_modules)` →
    `check(modules, prefix, ebin)` → `load(ebin, modules)`;
  - `compile/3` refuses any module the scan didn't predict;
  - `check/3` loads nothing;
  - a plugin ebin is never prepended to the code path.

  Read the `@doc`s in `build.ex` for the exact signatures before writing
  Task 4.

## To do

- **Task 4**: `Beamdash.Plugins` registry GenServer plus `Compat`, in the
  plan and `plug-task-4-brief.md`. Wire it to the actual Task 3 interface
  above.
- **Task 5**: Settings → Plugins card, the nav Plugins menu, `PluginLive`
  and the CSS route.
- **Task 6**: the riak_core plugin, a separate Mix project at
  `/Users/d.skliarov/projects/elixir/beamdash-riak-core-plugin`. It doesn't
  exist yet.
  - It needs only the Task 2 API, so it can run in parallel with Task 4.
  - riak_core source for reading return shapes:
    `/Users/d.skliarov/projects/elixir/pace-keeper/deps/riak_core/src/`
    (riak_core_lite 0.11.1, app name `riak_core`; read only).
  - `git init` there only: no commit, remote or push. The user pushes to
    `git@github.com:dskliarov/beamdash-riak-core-plugin.git`.
  - Skip its brief's Step 5 until Task 4 exists, then add the beamdash-side
    integration test (`@moduletag :riak_core_plugin`, excluded by default).
- **Task 7**: verify everything, take headless-Chrome screenshots, run
  `graphify update .`, and do a final whole-feature review on the most
  capable model.

## Open minor follow-ups (for the final review)

- `Spec`: `emit_warnings: false` needs Elixir 1.16. On 1.15 it is ignored
  and only causes a stderr warning.
- `Build` on Elixir 1.15/1.16: it's unverified whether compile loads a
  clashing module eagerly. Only 1.20 is installed.
- `Build`: `loaded_since` could purge an unrelated in-memory module loaded
  during a failed compile (a small window).
- `Fetch`: `mkdir` and `chmod` are two steps, a brief window for
  `default_hex_cmd/2` under the shared temp dir. With no `kill` executable
  on the system, the timeout path can't close the port.
- The scan is best-effort by design. `apply/3`, `Code.eval_*` and atom-module
  calls pass it, and `compile/3` catches any that compile a module.

## Handy

- The Chrome binary for screenshots is
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`, run with
  `--headless=new --force-dark-mode`.
- To render a LiveView to HTML without `lazy_html`, follow
  `test/beamdash/logs_live_test.exs`: a throwaway test that writes
  `/tmp/*.html`. Delete it afterwards.
