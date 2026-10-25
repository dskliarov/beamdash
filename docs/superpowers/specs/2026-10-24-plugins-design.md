# Plugins

## Goal

Application-specific UI that lives outside beamdash. A plugin is a Mix
project. Settings → Plugins adds one by typing it the way it would go in a
`mix.exs` `deps` list, so it can come from Hex, from Git (GitHub or any Git
host) or from a local folder:

```elixir
{:riak_core_plugin, "0.0.1"}
{:riak_core_plugin, git: "https://github.com/dskliarov/beamdash-riak-core-plugin", tag: "0.0.1"}
{:riak_core_plugin, path: "~/projects/elixir/riak_core_plugin"}
```

beamdash fetches it, compiles it and loads it without a restart, and Remove
unloads it and deletes what beamdash fetched. When the attached node runs an
application a plugin supports, the tab bar shows a **Plugins** menu with a
sub-menu per plugin listing its pages.

First plugin: **riak_core** (Ring, Members, Vnodes, Handoffs), a separate
Mix project for `git@github.com:dskliarov/beamdash-riak-core-plugin.git`.

Trust model: a plugin runs inside beamdash with beamdash's full access to the
attached node, and compiling it runs its macros. Fetching runs none of its
code: beamdash never evaluates the plugin's `mix.exs`. Settings says so when
adding one. Only plugins the user trusts.

## The dependency field

One text field, parsed with `Code.string_to_quoted/1` and then checked as a
literal term. It is **never evaluated**, so the field itself cannot run
code. Accepted shapes (as in Mix):

- `{app, requirement}`: from Hex. `requirement` is a quoted string that
  `Version.parse_requirement/1` accepts (`"0.0.1"` means exactly that version,
  `"~> 0.1"` a range).
- `{app, opts}` or `{app, requirement, opts}` where `opts` is a keyword list
  of literal strings, with exactly one source:
  - Git: `git: url` or `github: "owner/repo"`, plus at most one of `tag:`,
    `branch:`, `ref:`. `url` is `https://…`, `git@host:…` or `ssh://…`
    (no `file://` or local paths: use `path:` for those).
  - Path: `path: dir` (`~` is expanded).
  - Hex: `hex: :package_name` when the package name differs from `app`
    (with a requirement).
- `app`: an atom matching `^[a-z][a-z0-9_]{0,63}$`. It is the plugin's id
  (URLs, folders), unique among installed plugins.
- Any other option (`override`, `only`, `runtime`, `compile`, `manager`,
  `app`, `sparse`, …) is refused with a message naming it.
- Common mistakes get a specific hint instead of a raw parse error, e.g.
  `{:riak_core_plugin, 0.0.1}` → "write the version as a string, as in mix.exs:
  `{:riak_core_plugin, "0.0.1"}`", and an unquoted URL → "put the URL in quotes".

The validated term (written back with `inspect/2`, never the typed text) is
what beamdash stores in `plugins.json` and what the fetch step uses.

## Plugin project layout

An ordinary Mix project:

```
mix.exs                    app: :riak_core_plugin, deps (see below)
lib/riak_core_plugin.ex    use Beamdash.Plugin, ...
lib/riak_core_plugin/*.ex  pages
priv/static/plugin.css     optional
```

- The entry module declares the plugin:

  ```elixir
  use Beamdash.Plugin,
    name: "riak_core",
    pages: [{"ring", "Ring", RiakCorePlugin.RingLive}, ...]
  ```

  This generates `__beamdash_plugin__/0`. beamdash finds the plugin's entry
  module as the one compiled module exporting it (exactly one required).
- Which applications, and which versions, the plugin supports is declared in
  its `mix.exs` `deps`, the normal Mix way. Each supported application is a
  dependency marked `runtime: false` (or `only: :dev`/`:test` plus
  `runtime: false`):

  ```elixir
  defp deps do
    [
      {:riak_core, "~> 0.10", hex: :riak_core_lite, runtime: false},
      {:phoenix_live_view, "~> 1.0"},
      {:beamdash, path: "../beamdash", only: [:dev, :test], runtime: false}
    ]
  end
  ```

  beamdash reads these deps as data (never evaluating `mix.exs`) and splits
  them:
  - `{:beamdash, …}`: the beamdash version the plugin needs. Its requirement,
    if it has one, is checked against beamdash's own version (`mix.exs`
    `version`) at install. A `path:`/`git:` beamdash dep with no requirement
    accepts any beamdash.
  - Libraries beamdash ships (`phoenix_live_view`, `phoenix`, `jason`, …):
    their requirement is checked against beamdash's loaded version at
    install.
  - Every other dep with `runtime: false` is a **supported application**: its
    name is the application to look for on the attached node, and its
    requirement (may be absent: any version) the versions supported. The
    `hex:`/`git:` source is ignored by beamdash: it only matters when
    developing the plugin (it lets the plugin's own tests and editor see the
    application's modules, e.g. riak_core's specs).
  - Any other dep (runtime, not shipped by beamdash) refuses the install:
    "needs <dep>, which beamdash doesn't ship".
  - At least one supported application is required.

  The requirement must be a literal string; a dep list that isn't literal
  (built by a function call, module attribute, or `if`) is refused with a
  message saying so.
- Module names: every module the plugin defines must be the entry module or
  nested under it (`RiakCorePlugin.*`). Anything else (e.g. `Beamdash.*`,
  `Phoenix.*`, another plugin's prefix) refuses the install.
- Active: the plugin is active when at least one of its supported
  applications runs on the attached node **at a version matching its
  requirement**. The version comes from the node's running applications
  (`beamdash_agent:applications/0`, which already returns `vsn`). A running
  app at a non-matching version keeps the plugin inactive, and the menu and
  page say why (see below).
- `mix.exs` must set `app:` to the dependency's name in `project/0` as a
  literal (`app: :riak_core_plugin`). beamdash reads it as data, without
  evaluating the file.
- Code dependencies: a plugin may only use libraries beamdash already ships
  (Elixir, Phoenix, Phoenix LiveView, Jason, …). beamdash does not fetch the
  plugin's dependencies; it compiles the plugin against its own loaded
  copies. After compiling it checks every module the plugin calls (the
  beams' imports) and refuses the plugin if one isn't loaded or available in
  beamdash, naming it. Supported applications' modules are not a problem
  here: a plugin reaches them only through
  `Beamdash.Plugin.rpc(:riak_core_ring, :all_owners, [ring])`, where the
  module is just an atom argument, not an import. A direct local call like
  `:riak_core_ring.all_owners(ring)` shows up as an import of a module
  beamdash doesn't have, and the plugin is refused. It would only crash in
  beamdash, so the refusal message says to use `Beamdash.Plugin.rpc`.

## Plugin API (in beamdash, documented, kept stable)

- `use Beamdash.Plugin, name:, pages: [{slug, label, live_module}]` in the
  entry module. (Supported applications and versions come from `mix.exs`.) `slug`: `^[a-z][a-z0-9_-]{0,31}$`.
- `use Beamdash.Plugin.Page` in each page module: a LiveView that gets
  `@node` (the attached node or `nil`), `@syntax` and `@plugin` (the plugin's
  declaration), and re-renders on connect and disconnect (`{:beamdash_target, _}`
  is handled by the macro, which calls an optional `connection_changed/2`).
- `Beamdash.Plugin.rpc(mod, fun, args, timeout \\ 5_000)` →
  `{:ok, result} | {:error, :not_connected | term}`, run on the attached node
  (wraps `Beamdash.Target`).
- `Beamdash.Plugin.app_running?(app)` and `Beamdash.Plugin.app_version(app)`
  (`{:ok, "0.11.1"} | :not_running`).
- `Beamdash.Plugin.Format`: delegates to `Beamdash.Format` (`term/2`,
  `pid/2`, `mfa/2`, and `bytes/1` if present).
- Plugin CSS: `priv/static/plugin.css`, served at `/plugins/<id>/plugin.css`
  and added to that plugin's pages only. Class names should be prefixed with
  the plugin id.

## Storage

- Plugins directory: `<user config dir>/beamdash/plugins/` (macOS
  `~/Library/Application Support/beamdash/plugins/`), overridden by
  `config :beamdash, :plugins_dir`.
- One folder per plugin, `<plugins dir>/<app>/`:
  - `src/`: the fetched source (a Git clone or an unpacked Hex package).
    Path plugins have no `src/`; their folder is used in place.
  - `ebin/`: the plugin's compiled `.beam` files.
  - The plugin's `priv/static/plugin.css` is read from its source.
- `<plugins dir>/plugins.json` lists the installed plugins:
  `[{"app", "spec" (as written back by inspect), "source" ("hex"|"git"|"path"),
  "resolved" (Hex version, Git commit, or the path), "supports"
  ([{"app", "requirement" | null}], from mix.exs), "installed_at"}]`.

## Install (Settings → Plugins → Add)

Run in a supervised Task (never in the LiveView or in the registry's
`handle_call`), each step reported to the page:

1. **Check** the field (above). The `app` must not be installed already.
2. **Fetch** the plugin's own source into `<tmp>/src`. Its dependencies are
   not fetched.
   - Git: `git clone --depth 1 [--branch <tag|branch>] <url>`. A `ref:` gets
     a full clone, then `git checkout <ref>`. `github: "o/r"` means
     `https://github.com/o/r.git`. The environment has
     `GIT_TERMINAL_PROMPT=0` and the timeout is 120 s. Git uses the user's own
     Git and SSH setup, and beamdash never asks for credentials.
   - Hex: resolve the requirement to the highest matching release from
     `mix hex.info <package>`, then
     `mix hex.package fetch <package> <version> --unpack --output <tmp>/src`
     (an OS process, 120 s). Requires `mix` with Hex on `PATH`.
   - Path: nothing is copied. The source is the expanded folder, which must
     exist.
3. **Read `mix.exs`** as data (`Code.string_to_quoted/1`). `project/0` must
   contain `app: :<name>` equal to the dependency's name, and `deps:` must be
   a literal list or call a `defp deps` returning one. Split the deps as in
   "Plugin project layout": check the beamdash and shipped-library
   requirements, record the supported applications and their requirements,
   refuse other runtime deps.
4. **Scan the sources** before compiling (`lib/**/*.ex`, parsed, not run).
   Every `defmodule` name, with nested names resolved against their parent,
   must be under one top-level prefix. None may already be loaded by
   beamdash or another plugin.
   - Why before compiling: compiling in the running VM would otherwise
     replace a beamdash module of the same name.
   - `defimpl` is allowed only `for:` a module under that prefix.
5. **Compile** with `Kernel.ParallelCompiler.compile_to_path/3` into
   `<tmp>/ebin`, in the running beamdash, so the plugin builds against
   beamdash's loaded `Beamdash.Plugin`, Phoenix and LiveView. Warnings and
   errors are captured.
6. **Check the result:**
   - exactly one module exports `__beamdash_plugin__/0`, and it is the
     prefix module;
   - every compiled module is under the prefix;
   - the pages are valid;
   - every remote module the beams import is loaded in beamdash, available on
     its code path, or belongs to a supported application (see "Code
     dependencies").

   On failure the compiled modules are purged.
7. **Load**: move `<tmp>` to `<plugins dir>/<app>/`, add its `ebin` to the
   code path, record the Hex version, Git commit (`git rev-parse HEAD`) or
   path, and save `plugins.json`.

Any failure deletes `<tmp>`, leaves nothing loaded, and shows the error under
the form (git, Hex or compiler output, trimmed).

## Remove

A confirm dialog, then: unload every plugin module (`:code.purge/1` and
`:code.delete/1`), remove its `ebin` from the code path, delete
`<plugins dir>/<app>/` and update `plugins.json`.

What is deleted depends on the plugin's source:

- **Hex and Git plugins:** `<plugins dir>/<app>/` is deleted, including the
  fetched source in its `src/`. beamdash fetched that code, so it removes it.
- **Path plugins:** the source folder is **never** deleted, and the dialog
  offers no option to delete it. Only `<plugins dir>/<app>/` goes, which
  holds just the compiled `ebin/`. The confirm
  dialog says: "Your folder `<path>` is not touched."
- **Guard:** before deleting, beamdash checks that the target is inside
  `<plugins dir>/` (after expanding the path and resolving symlinks). It
  also checks that it isn't the plugins directory itself. Anything else is
  refused with an error. A path plugin's source is therefore never deleted,
  even through a bad `plugins.json` entry or a symlink.
- **Order and failure:** the plugin is unloaded first. If its folder can't
  be deleted, the plugin stays removed, and the error is shown together with
  the folder path so it can be deleted by hand.

Open pages of a removed plugin get `{:beamdash_plugins, {:removed, app}}` and
show "Plugin removed".

## Rebuild (path plugins)

Path plugins also get a **Rebuild** button, for developing a plugin locally.
It recompiles from the folder (steps 3–7, skipping the fetch), and swaps the
modules in place. On failure the old version stays loaded and the error is
shown.

## Startup

`Beamdash.Plugins` (a GenServer started after `Beamdash.Target`) reads
`plugins.json` and loads each plugin from its `ebin`. It recompiles first when
`ebin` is missing or, for a path plugin, when any source file is newer than
the beams. A plugin that fails to load is listed as `{:failed, reason}`;
beamdash starts anyway. Startup never fetches from the network.

## Active plugins and the menu

- `Beamdash.Plugins` subscribes to `Target`. On connect, and every 10 s while
  connected, it asks the node for its running applications and their
  versions (the existing `beamdash_agent:applications/0`) and recomputes, per
  loaded plugin:
  - `:active`: a supported application runs at a matching version;
  - `{:incompatible, app, running_vsn, requirement}`: a supported
    application runs, but no running one matches (versions that aren't valid
    SemVer, e.g. `"2.1"`, are padded to `"2.1.0"`; still unparsable → treated
    as not matching, and the reason says so);
  - `:waiting`: none of its applications runs.

  Changes are broadcast as `{:beamdash_plugins, :changed}` on PubSub topic
  `"plugins"`.
- Only `:active` plugins appear in the menu. A plugin page opened directly
  for an `:incompatible` plugin says "riak_core 0.9.0 is running; this plugin
  supports ~> 0.10" instead of loading the page.
- The tab bar (`BeamdashWeb.Layouts.nav/1`) shows a **Plugins** menu after the
  Tracing group when any plugin is active:
  `Plugins ▾ → <plugin name> ▸ → <page label>`, linking to
  `/plugins/<app>/<slug>`. There is no `g` shortcut. The NavOverflow "More"
  menu keeps working, with Plugins as one item.
- `BeamdashWeb.Connection`'s hook keeps `@plugins_active` current for the bar.

## Routing and pages

- `live "/plugins/:plugin/:page", BeamdashWeb.PluginLive` in the same
  `live_session`.
- `PluginLive` looks the page up in `Beamdash.Plugins`:
  - unknown plugin or page: "No such plugin page", with a link to Settings;
  - plugin waiting: beamdash's header plus "<name> needs riak_core
    (~> 0.10) running on the attached node";
  - plugin incompatible: "riak_core 0.9.0 is running; this plugin supports
    ~> 0.10";
  - otherwise beamdash's header with the plugin's LiveView embedded through
    `live_render(socket, page_module, id: "plugin-#{app}-#{slug}", session: %{…})`.
    The plugin runs in its own process, so a crash there shows LiveView's
    error state for that region only and beamdash's header keeps working.

## Settings → Plugins section

- **List**: name, app, the spec as installed, a source badge (hex / git /
  path), the resolved version / short commit / path, the supported
  applications with their requirements (`riak_core ~> 0.10`), and a status:
  `active`, `installed, waiting for riak_core`, `riak_core 0.9.0 running,
  needs ~> 0.10`, or `failed: reason`. Buttons: **Remove**,
  and **Rebuild** for path plugins.
- **Add form**:
  - one field, "Mix dependency", placeholder `{:riak_core_plugin, "~> 0.1"}`;
  - three examples under it (Hex, Git with tag, local path);
  - the warning: "A plugin runs inside beamdash with full access to the nodes
    you connect to, and fetching it runs its mix.exs. Add only plugins you
    trust.";
  - progress: Checking… / Fetching… / Compiling… / Loaded, or the error.
- Shows the plugins directory path.

## The riak_core plugin (separate project)

Built locally at `../beamdash-riak-core-plugin` (a sibling of beamdash),
with its own Git history. The user pushes it to
`git@github.com:dskliarov/beamdash-riak-core-plugin.git`, tags `0.0.1`, and
can later publish it to Hex as `riak_core_plugin`. It installs as any of:

```elixir
{:riak_core_plugin, path: "~/projects/elixir/beamdash-riak-core-plugin"}
{:riak_core_plugin, git: "https://github.com/dskliarov/beamdash-riak-core-plugin", tag: "0.0.1"}
{:riak_core_plugin, "0.0.1"}   # once on Hex
```

- `mix.exs`: `app: :riak_core_plugin`, `version: "0.0.1"`, deps:
  - `{:riak_core, "~> 0.10", hex: :riak_core_lite, runtime: false}`: the
    supported application and versions (pace-keeper runs riak_core_lite
    0.11.1, whose application name is `riak_core`);
  - `{:phoenix_live_view, "~> 1.0"}` (shipped by beamdash);
  - `{:beamdash, path: "../beamdash", only: [:dev, :test], runtime: false}`
    for its own tests.

  A Hex `package` section is ready for later.
- Entry module `RiakCorePlugin`: `name: "riak_core"`, four pages. Each page refreshes every 5 s, gets all its data through
  `Beamdash.Plugin.rpc`, and works with both riak_core and riak_core_lite,
  which share these APIs (checked against the riak_core_lite that
  pace-keeper uses).
  - **Ring** (`ring`): `riak_core_ring_manager:get_my_ring/0` →
    `riak_core_ring:num_partitions/1`, `all_owners/1`, `claimant/1`,
    `pending_changes/1`; `riak_core_status:ringready/0`. Shows ring size,
    claimant, ring-ready state, partitions per node, and the partition list
    (index, owner, pending next owner), filterable by node.
  - **Members** (`members`): `riak_core_ring:all_member_status/1`, with
    up/down from `erlang:nodes/0` on the target. Shows node, status (valid /
    joining / leaving / exiting / down), partitions owned, and up/down.
  - **Vnodes** (`vnodes`): `riak_core_vnode_manager:all_vnodes/0` →
    `{Mod, Index, Pid}`, plus `erlang:process_info/2` per pid (mailbox,
    memory, reductions), one rpc per page refresh for ring sizes up to 1,024.
    Sortable table with a module filter.
  - **Handoffs** (`handoffs`): `riak_core_handoff_manager:status/0` (active)
    and `riak_core_ring:pending_changes/1` (pending). Shows type, module,
    partition, from → to node, size or progress when reported, and start time.
  - An rpc returning `undef` for a riak_core module shows "riak_core is not
    running". Other rpc errors are shown as they are.
- Tests in the plugin project: data shaping from recorded rpc results (no
  riak_core needed). Manual check: install by `path:` in beamdash and
  connect to pace-keeper.

## Tests (beamdash)

- **Dependency field**:
  - each accepted shape (Hex, Git url/github with tag/branch/ref, path,
    hex: rename);
  - refused options and multiple sources;
  - the unquoted-version and unquoted-URL hints;
  - proof that it is never evaluated (e.g. `{:x, System.halt()}` is refused,
    not run).
- **Install** with `path:` and with `git:` pointing at a temp local repo
  (the `file://` restriction is lifted only by a test-config flag,
  `:plugins_allow_local_git`), using a fixture plugin under
  `test/fixtures/plugins/hello_plugin/`:
  - modules loaded, `plugins.json` written;
  - namespace violation refused and nothing left behind;
  - compile error shown, nothing left behind;
  - an unshipped runtime dependency refused;
  - a `{:beamdash, "~> 99.0", runtime: false}` dep refused;
  - a non-literal `deps` (e.g. `deps: deps() ++ extra()`) refused;
  - the fixture's `{:hello_app, "~> 1.0", runtime: false}` recorded as a
    supported application with its requirement;
  - a page that calls `:hello_app_mod.f()` directly is refused, with a
    message that suggests `Beamdash.Plugin.rpc`. A page that passes
    `:hello_app_mod` to `Beamdash.Plugin.rpc` is accepted.
- **Remove**:
  - a Git plugin's `<plugins dir>/<app>/` is gone, fetched code included, and
    its modules are purged;
  - a path plugin's source folder is untouched, file for file, and only its
    `<plugins dir>/<app>/` is gone;
  - the dialog for a path plugin offers no delete-folder option and says the
    folder is not touched;
  - the guard refuses to delete anything outside `<plugins dir>/`, even when
    a `plugins.json` entry or a symlink points at the source folder.
- **Rebuild** of a path plugin picks up an edited page; a broken edit keeps
  the old version loaded.
- **Startup reload** from `plugins.json`, recompiling a path plugin whose
  sources are newer; a broken plugin is `{:failed, _}` while the others load.
- **Active set**: a peer running `:hello_app` at vsn `1.2.0` makes the
  fixture active (`~> 1.0`), `{:beamdash_plugins, :changed}` is broadcast,
  and the nav renders the Plugins menu; at vsn `2.0.0` it is
  `{:incompatible, :hello_app, "2.0.0", "~> 1.0"}` and not in the menu; a
  non-SemVer vsn `"1.2"` matches `~> 1.0`; not running → `:waiting`.
- **`PluginLive`**: unknown page, inactive plugin, and an active plugin whose
  page's `Beamdash.Plugin.rpc` reaches the peer.
- **Settings**: Add (with progress and errors), Remove, Rebuild.
- Hex fetching is not exercised against hex.pm (no network in tests). The
  Hex fetch is behind a `:plugins_hex_cmd` seam, and a test replaces it with
  a script that unpacks the fixture.
- A plugin calling a module beamdash doesn't ship (fixture `NotShipped.call/0`)
  is refused, naming the module. A plugin defining `Beamdash.Format` is
  refused before compiling, and beamdash's `Beamdash.Format` is unchanged.
- Tests never touch the real plugins dir (`test_helper` sets `:plugins_dir`).

## Out of scope (for now)

Updating a Hex or Git plugin to a newer version (remove and add again);
plugins loading their own code into the target node; plugins bringing
libraries beamdash doesn't ship; running beamdash as a release (compiling
plugins needs the Elixir compiler; Hex plugins need `mix` with Hex on `PATH`); a plugin catalogue.
