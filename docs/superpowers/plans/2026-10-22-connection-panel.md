# Connection Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tidy the header's Direct / Kubernetes connection controls and give the namespace field suggestions from the cluster while still accepting any typed name.

**Architecture:** `Beamdash.Kubectl.list_namespaces/2` lists namespaces; `BeamdashWeb.Connection` stores them in `@conn.kube_namespaces` (silently `[]` on failure); `BeamdashWeb.Layouts.header/1` renders them as a native `<datalist>` on the namespace input, and a tiny `NamespacePick` JS hook submits the form when a suggestion is picked. Layout moves to a bordered panel of `label | control | action` grid rows.

**Tech Stack:** Elixir, Phoenix LiveView (HEEx), plain CSS (`priv/static/assets/app.css`), plain JS hooks (`priv/static/assets/app.js`, no build step).

Spec: `docs/superpowers/specs/2026-10-22-connection-panel-design.md`

## Global Constraints

- Keep existing element ids, event names and field names: `connect-form`, `select-kube-cluster-form`, `list-kube-pods-form`, `select-kube-pod-form`, `select-kube-container-form`, `connect-kubectl-form`; events `set_conn_method`, `connect`, `select_kube_cluster`, `list_kube_pods`, `select_kube_pod`, `select_kube_container`, `connect_kubectl`.
- A failed namespace listing never sets `@conn.error`.
- No commits: the working tree holds the user's uncommitted exberly→beamdash rename, including `app.css`, `app.js`. Leave changes uncommitted.
- Before reading code for a question, run `graphify query "<question>"` (`graphify` is on PATH). After code changes run `graphify update .`.

---

### Task 1: `Kubectl.list_namespaces/2`

**Files:**
- Modify: `lib/beamdash/kubectl.ex` (insert after `list_pods/3`, ~line 91)
- Test: `test/beamdash/kubectl_test.exs` (new `describe` after `list_pods/3`, ~line 77)

**Interfaces:**
- Produces: `Beamdash.Kubectl.list_namespaces(kubeconfig :: String.t() | nil, exec \\ &run_kubectl/1) :: {:ok, [String.t()]} | {:error, {:namespace_list_failed, term()}}`

- [ ] **Step 1: Write the failing tests** (insert after the `list_pods/3` describe block)

```elixir
  describe "list_namespaces/2" do
    test "parses a jsonpath namespace list" do
      exec = fn args ->
        assert args == ["get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"]
        {"default kube-system pace-keeper\n", 0}
      end

      assert {:ok, ["default", "kube-system", "pace-keeper"]} =
               Kubectl.list_namespaces(nil, exec)
    end

    test "passes --kubeconfig when a cluster is given" do
      exec = fn args ->
        assert args == [
                 "--kubeconfig",
                 "/home/me/.kube/prod.yaml",
                 "get",
                 "namespaces",
                 "-o",
                 "jsonpath={.items[*].metadata.name}"
               ]

        {"default\n", 0}
      end

      assert {:ok, ["default"]} = Kubectl.list_namespaces("/home/me/.kube/prod.yaml", exec)
    end

    test "a non-zero exit is reported" do
      exec = fn _args -> {"namespaces is forbidden", 1} end

      assert {:error, {:namespace_list_failed, {1, "namespaces is forbidden"}}} =
               Kubectl.list_namespaces(nil, exec)
    end

    test "an exception from exec is caught and reported" do
      exec = fn _args -> raise "boom" end

      assert {:error, {:namespace_list_failed, {:error, %RuntimeError{}}}} =
               Kubectl.list_namespaces(nil, exec)
    end
  end
```

- [ ] **Step 2: Run, expect failure**

Run: `mix test test/beamdash/kubectl_test.exs`
Expected: 4 failures, `function Beamdash.Kubectl.list_namespaces/2 is undefined`.

- [ ] **Step 3: Implement** (insert after `list_pods/3`'s `end`)

```elixir
  @doc """
  Namespaces in the cluster `kubeconfig` points at, offered as suggestions
  in the namespace field (a cluster whose RBAC forbids listing them gives
  an error; the field then just takes the typed name).
  """
  @spec list_namespaces(String.t() | nil, (list(String.t()) -> {binary(), integer()})) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_namespaces(kubeconfig, exec \\ &run_kubectl/1) do
    args =
      kubeconfig_args(kubeconfig) ++
        ["get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"]

    case exec.(args) do
      {output, 0} ->
        {:ok, output |> String.trim() |> String.split(~r/\s+/, trim: true)}

      {output, status} ->
        {:error, {:namespace_list_failed, {status, String.trim(output)}}}
    end
  catch
    kind, reason -> {:error, {:namespace_list_failed, {kind, reason}}}
  end
```

- [ ] **Step 4: Run, expect pass**

Run: `mix test test/beamdash/kubectl_test.exs`
Expected: all pass.

---

### Task 2: Connection hook fetches namespaces

**Files:**
- Modify: `lib/beamdash_web/connection.ex` (mount assigns ~line 41; `set_conn_method` ~line 96; `select_kube_cluster` ~line 102; `handle_info({:beamdash_kubeconfig_dir, _})` ~line 253; new private helper near `list_containers/4` ~line 284)
- Test: `test/beamdash/connection_bar_test.exs`

**Interfaces:**
- Consumes: `Kubectl.list_namespaces/2` (Task 1)
- Produces: `@conn.kube_namespaces :: [String.t()]` (default `[]`), read by Task 3's template.

- [ ] **Step 1: Write the failing test** (append before the final `end`)

```elixir
  test "switching to Kubernetes on a cluster that cannot list namespaces offers none, quietly" do
    # an empty kubeconfig: kubectl fails (or is missing), like an RBAC refusal
    path = Path.join(System.tmp_dir!(), "beamdash-empty-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)

    conn = Map.merge(socket().assigns.conn, %{kube_cluster: path, kube_namespaces: ["stale"]})
    s = Phoenix.Component.assign(socket(), :conn, conn)

    {:halt, s} = Connection.handle_event("set_conn_method", %{"method" => "kubectl"}, s)
    assert s.assigns.conn.method == :kubectl
    assert s.assigns.conn.kube_namespaces == []
    assert s.assigns.conn.error == nil

    {:halt, s} = Connection.handle_event("set_conn_method", %{"method" => "direct"}, s)
    assert s.assigns.conn.method == :direct
  end

  test "a freshly mounted bar offers no namespaces yet" do
    assert mounted_bar().assigns.conn.kube_namespaces == []
  end
```

- [ ] **Step 2: Run, expect failure**

Run: `mix test test/beamdash/connection_bar_test.exs`
Expected: both new tests fail (`kube_namespaces` still `["stale"]` / key missing).

- [ ] **Step 3: Implement**

In `on_mount/4`'s map, after `kube_namespace: "",` add:

```elixir
          kube_namespaces: [],
```

Replace `set_conn_method`:

```elixir
  # namespaces are re-listed each time Kubernetes is picked, so ones created
  # meanwhile show up too
  def handle_event("set_conn_method", %{"method" => method}, socket) do
    method = String.to_existing_atom(method)
    socket = update(socket, method: method, error: nil)
    {:halt, if(method == :kubectl, do: list_namespaces(socket), else: socket)}
  end
```

In `select_kube_cluster`, add `kube_namespaces: [],` to the `update` list and pipe the result through `list_namespaces/1`:

```elixir
  def handle_event("select_kube_cluster", %{"cluster" => cluster}, socket) do
    {:halt,
     socket
     |> update(
       kube_cluster: cluster,
       kube_namespaces: [],
       kube_pods: nil,
       kube_pod: "",
       kube_containers: nil,
       kube_container: nil,
       kube_binaries: nil,
       kube_binary: nil,
       error: nil
     )
     |> list_namespaces()}
  end
```

In `handle_info({:beamdash_kubeconfig_dir, dir}, socket)`, add `kube_namespaces: [],` to the reset list and re-list when the Kubernetes method is showing:

```elixir
    socket =
      socket
      |> update(
        kube_namespaces: [],
        kube_pods: nil,
        kube_pod: "",
        kube_containers: nil,
        kube_container: nil,
        kube_binaries: nil,
        kube_binary: nil,
        error: nil
      )
      |> update(kube_clusters(dir))

    {:halt, if(socket.assigns.conn[:method] == :kubectl, do: list_namespaces(socket), else: socket)}
```

Add the helper above `list_containers/4`:

```elixir
  # Suggestions for the namespace field. A cluster that forbids listing
  # namespaces (RBAC) just offers none, without an error: the field still
  # takes whatever name is typed.
  defp list_namespaces(%{assigns: %{conn: %{kube_cluster: nil}}} = socket),
    do: update(socket, kube_namespaces: [])

  defp list_namespaces(socket) do
    namespaces =
      case Kubectl.list_namespaces(socket.assigns.conn.kube_cluster) do
        {:ok, namespaces} -> namespaces
        {:error, _} -> []
      end

    update(socket, kube_namespaces: namespaces)
  end
```

Note: the test's `socket()` conn has no `:kube_cluster` key at first; it is merged in. `list_namespaces/1` pattern only matches `nil`, so a path goes to the second clause.

- [ ] **Step 4: Run, expect pass**

Run: `mix test test/beamdash/connection_bar_test.exs test/beamdash/settings_test.exs`
Expected: all pass.

---

### Task 3: Panel layout, namespace datalist, `NamespacePick` hook

**Files:**
- Modify: `lib/beamdash_web/layouts.ex:51-215` (the `connect-methods` block)
- Modify: `priv/static/assets/app.css:800-814` (replace the connection-bar rules, keep `.node-info*` and `.conn-error`)
- Modify: `priv/static/assets/app.js` (new hook before `const csrfToken`, register in `hooks:`)
- Test: `test/beamdash/connection_bar_test.exs`

**Interfaces:**
- Consumes: `@conn.kube_namespaces` (Task 2)
- Produces: DOM ids `kube-namespace` (input, `phx-hook="NamespacePick"`), `kube-namespace-list` (datalist)

- [ ] **Step 1: Write the failing tests** (append before the final `end`)

```elixir
  defp kube_socket(namespaces) do
    Phoenix.Component.assign(
      socket(),
      :conn,
      Map.merge(socket().assigns.conn, %{
        method: :kubectl,
        kube_clusters: [%{name: "prod", path: "/k/prod.yaml"}],
        kube_cluster: "/k/prod.yaml",
        kube_namespace: "",
        kube_namespaces: namespaces
      })
    )
  end

  test "the namespace field suggests the cluster's namespaces and still takes any name" do
    html = bar(kube_socket(["default", "pace-keeper"]))
    assert html =~ ~s(id="kube-namespace")
    assert html =~ ~s(list="kube-namespace-list")
    assert html =~ ~s(phx-hook="NamespacePick")
    assert html =~ ~s(<datalist id="kube-namespace-list">)
    assert html =~ ~s(<option value="pace-keeper">)
    assert html =~ ~r/>\s*Cluster\s*</
    assert html =~ ~r/>\s*Namespace\s*</

    html = bar(kube_socket([]))
    assert html =~ ~s(id="kube-namespace")
    refute html =~ "<datalist"
    refute html =~ ~s(list="kube-namespace-list")
  end

  test "Direct shows labelled Node and Cookie fields" do
    html = bar(socket())
    assert html =~ ~r/>\s*Node\s*</
    assert html =~ ~r/>\s*Cookie\s*</
    assert html =~ ~s(class="seg method-switch")
  end
```

- [ ] **Step 2: Run, expect failure**

Run: `mix test test/beamdash/connection_bar_test.exs`
Expected: the two new tests fail (no `kube-namespace` id, no labels).

- [ ] **Step 3: Replace the template** — `lib/beamdash_web/layouts.ex`, the whole `<div :if={@conn.status != :connected} class="connect-methods"> … </div>` block (lines 52–215) becomes:

```heex
        <div :if={@conn.status != :connected} class="connect-panel">
          <div class="seg method-switch" role="group" aria-label="Connection method">
            <button
              type="button"
              class={["seg-btn", Map.get(@conn, :method, :direct) == :direct && "active"]}
              phx-click="set_conn_method"
              phx-value-method="direct"
            >
              Direct
            </button>
            <button
              type="button"
              class={["seg-btn", Map.get(@conn, :method, :direct) == :kubectl && "active"]}
              phx-click="set_conn_method"
              phx-value-method="kubectl"
            >
              {kube_method_label()}
            </button>
          </div>

          <form
            :if={Map.get(@conn, :method, :direct) == :direct}
            id="connect-form"
            phx-submit="connect"
            class="conn-rows"
          >
            <div class="conn-row">
              <label class="field-label" for="conn-node">Node</label>
              <input
                id="conn-node"
                class="wide"
                name="node"
                value={@conn.node_input}
                placeholder="node@host"
                required
                autocomplete="off"
              />
            </div>
            <div class="conn-row">
              <label class="field-label" for="conn-cookie">Cookie</label>
              <input
                id="conn-cookie"
                name="cookie"
                type="password"
                value={Map.get(@conn, :cookie_input, "")}
                placeholder="optional"
                autocomplete="off"
              />
              <button type="submit" phx-disable-with="Connecting…">Connect</button>
            </div>
          </form>

          <div :if={Map.get(@conn, :method, :direct) == :kubectl} class="conn-rows">
            <form
              :if={Map.get(@conn, :kube_clusters, []) != []}
              id="select-kube-cluster-form"
              phx-change="select_kube_cluster"
              class="conn-row"
            >
              <label class="field-label" for="kube-cluster">Cluster</label>
              <select id="kube-cluster" class="wide" name="cluster">
                <option
                  :for={c <- @conn.kube_clusters}
                  value={c.path}
                  selected={c.path == @conn.kube_cluster}
                >
                  {c.name}
                </option>
              </select>
            </form>
            <p :if={Map.get(@conn, :kube_clusters, []) == []} class="conn-hint muted small">
              No kubeconfig files found under <span class="mono">{Map.get(@conn, :kube_dir, "~/.kube")}</span>.
              <span :if={@conn[:kube_cluster_error]}>{@conn.kube_cluster_error}.</span>
              The directory can be changed in <a href="/settings">Settings</a>.
            </p>

            <form
              :if={Map.get(@conn, :kube_clusters, []) != []}
              id="list-kube-pods-form"
              phx-submit="list_kube_pods"
              class="conn-row"
            >
              <label class="field-label" for="kube-namespace">Namespace</label>
              <input
                id="kube-namespace"
                name="namespace"
                list={Map.get(@conn, :kube_namespaces, []) != [] && "kube-namespace-list"}
                phx-hook="NamespacePick"
                value={Map.get(@conn, :kube_namespace, "")}
                placeholder={
                  if Map.get(@conn, :kube_namespaces, []) != [],
                    do: "type or pick a namespace",
                    else: "namespace"
                }
                required
                autocomplete="off"
              />
              <datalist :if={Map.get(@conn, :kube_namespaces, []) != []} id="kube-namespace-list">
                <option :for={ns <- @conn.kube_namespaces} value={ns} />
              </datalist>
              <button
                type="submit"
                class="secondary"
                phx-disable-with="Listing…"
                disabled={Map.get(@conn, :kube_pods_listing, false)}
              >
                List pods
              </button>
            </form>

            <form
              :if={Map.get(@conn, :kube_pods)}
              id="select-kube-pod-form"
              phx-change="select_kube_pod"
              class="conn-row"
            >
              <input type="hidden" name="namespace" value={Map.get(@conn, :kube_namespace, "")} />
              <label class="field-label" for="kube-pod">Pod</label>
              <select
                id="kube-pod"
                name="pod"
                class="wide pod-select"
                disabled={@conn.kube_pods == []}
              >
                <option :for={p <- @conn.kube_pods} value={p} selected={p == @conn.kube_pod}>
                  {p}
                </option>
              </select>
            </form>
            <p :if={@conn[:kube_pods] == []} class="conn-hint muted small">
              No pods found in this namespace.
            </p>

            <form
              :if={Map.get(@conn, :kube_containers) && length(@conn.kube_containers) > 1}
              id="select-kube-container-form"
              phx-change="select_kube_container"
              class="conn-row"
            >
              <input type="hidden" name="namespace" value={Map.get(@conn, :kube_namespace, "")} />
              <input type="hidden" name="pod" value={Map.get(@conn, :kube_pod, "")} />
              <label class="field-label" for="kube-container">Container</label>
              <select id="kube-container" class="wide" name="container">
                <option
                  :for={c <- @conn.kube_containers}
                  value={c}
                  selected={c == @conn.kube_container}
                >
                  {c}
                </option>
              </select>
            </form>

            <form
              :if={Map.get(@conn, :kube_binaries)}
              id="connect-kubectl-form"
              phx-submit="connect_kubectl"
              class="conn-row"
            >
              <input type="hidden" name="namespace" value={Map.get(@conn, :kube_namespace, "")} />
              <input type="hidden" name="pod" value={Map.get(@conn, :kube_pod, "")} />
              <input type="hidden" name="container" value={Map.get(@conn, :kube_container, "")} />
              <label class="field-label" for="kube-binary">Binary</label>
              <select id="kube-binary" name="binary" disabled={@conn.kube_binaries == []}>
                <option
                  :for={bin <- @conn.kube_binaries}
                  value={bin}
                  selected={bin == @conn.kube_binary}
                >
                  {bin}
                </option>
              </select>
              <button
                type="submit"
                phx-disable-with="Connecting…"
                disabled={@conn.kube_binaries == []}
              >
                Connect
              </button>
            </form>
            <p :if={@conn[:kube_binaries] == []} class="conn-hint muted small">
              No binaries found under /app/bin in this pod{if @conn[:kube_container],
                do: " (container #{@conn.kube_container})"}.
            </p>
          </div>
        </div>
```

(`<label for>` replaces the old `aria-label`s, so the controls keep accessible names.)

- [ ] **Step 4: Replace the CSS** — in `priv/static/assets/app.css`, replace lines 800–814 (from `/* connection bar on every tab: node info on its own line */` through `.bar .connect-kubectl select.pod-select { … }`) with:

```css
/* connection panel on every tab: method switch, then label | control | action rows */
.connect-panel { display: flex; flex-direction: column; gap: 10px; width: 460px; max-width: 100%; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; }
.connect-panel .method-switch { align-self: flex-start; }
.connect-panel .method-switch .seg-btn { padding: 4px 14px; font-size: 13px; }
.conn-rows { display: flex; flex-direction: column; gap: 8px; margin: 0; }
.conn-row { display: grid; grid-template-columns: 76px minmax(0, 1fr) auto; align-items: center; gap: 8px; margin: 0; }
.conn-row .wide { grid-column: 2 / -1; }
.conn-row .field-label { font-size: 12px; color: var(--muted); white-space: nowrap; }
.connect-panel input,
.connect-panel select {
  box-sizing: border-box; width: 100%; min-width: 0; height: 32px; padding: 0 8px;
  font: inherit; color: var(--fg); background: var(--bg);
  border: 1px solid var(--line); border-radius: 6px;
}
.connect-panel input:focus,
.connect-panel select:focus { outline: none; border-color: var(--accent); }
.connect-panel select:disabled { opacity: .55; }
.connect-panel .conn-row button { box-sizing: border-box; height: 32px; padding: 0 14px; white-space: nowrap; }
.conn-hint { margin: 0 0 0 84px; }
```

- [ ] **Step 5: Add the JS hook** — in `priv/static/assets/app.js`, insert before `const csrfToken = …`:

```js
// Namespace input backed by a <datalist> of the cluster's namespaces:
// picking a suggestion lists that namespace's pods straight away, typing
// waits for Enter or "List pods" (any name is accepted).
const NamespacePick = {
  mounted() {
    this.el.addEventListener("input", (e) => {
      // a pick arrives without an inputType (Firefox) or as a replacement
      if (e.inputType && e.inputType !== "insertReplacementText") return;
      const options = this.el.list ? Array.from(this.el.list.options) : [];
      if (options.some((o) => o.value === this.el.value)) this.el.form.requestSubmit();
    });
  },
};
```

and change the hooks line to:

```js
  hooks: { Resizer, DockSpacer, NavOverflow, NamespacePick },
```

- [ ] **Step 6: Run, expect pass**

Run: `mix test test/beamdash/connection_bar_test.exs`
Expected: all pass, including the existing `connect-form`, cookie and Kubernetes-label tests.

---

### Task 4: Verify end to end

- [ ] **Step 1: Full suite + format**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: no warnings, all tests pass.

- [ ] **Step 2: Screenshot both methods** — render the header into static HTML and capture it with headless Chrome:

```bash
mix run --no-start -e '
for {name, conn} <- [
  direct: %{status: :disconnected, node: nil, info: nil, node_input: "foo@host", cookie_input: "", error: nil, method: :direct},
  kube: %{status: :disconnected, node: nil, info: nil, node_input: "", error: nil, method: :kubectl,
    kube_clusters: [%{name: "apse1-dsp-prod", path: "/k/a.yaml"}, %{name: "use1-rdev", path: "/k/b.yaml"}],
    kube_cluster: "/k/a.yaml", kube_namespace: "pace-keeper", kube_namespaces: ["default", "pace-keeper"],
    kube_pods: ["pace-keeper-0", "pace-keeper-1"], kube_pod: "pace-keeper-0",
    kube_containers: ["pace-keeper", "sidecar"], kube_container: "pace-keeper",
    kube_binaries: ["pace_keeper"], kube_binary: "pace_keeper"}
] do
  html = %{active: :gc, syntax: :erlang, conn: conn} |> BeamdashWeb.Layouts.header() |> Phoenix.HTML.Safe.to_iodata()
  File.write!("/tmp/bd_#{name}.html", ["<html class=dark><head><link rel=stylesheet href=\"file://#{File.cwd!()}/priv/static/assets/app.css\"></head><body>", html, "</body></html>"])
end'
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for n in direct kube; do "$C" --headless=new --disable-gpu --window-size=1400,420 --screenshot=/tmp/bd_$n.png file:///tmp/bd_$n.html; done
```

Expected: both PNGs show the bordered panel, segmented Direct/Kubernetes switch, labels aligned in one column, controls of equal height, Connect at the bottom right. Fix CSS and re-shoot if not.

- [ ] **Step 3: Live check of the namespace pick** — restart the app (`mix run --no-halt` or however it is normally run) and in the browser: Kubernetes → cluster `apse1-dsp-prod` → focus Namespace shows `default … pace-keeper`; typing `pace` filters; picking `pace-keeper` lists pods without pressing List pods; a typed unknown name + Enter still lists (or shows the kubectl error).

- [ ] **Step 4: Update the graph**

Run: `graphify update .`
