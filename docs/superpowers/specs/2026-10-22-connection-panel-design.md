# Connection panel: appearance and namespace suggestions

## Goal

Make the header's connection controls (Direct / Kubernetes) look tidy and
consistent, and let the user pick a Kubernetes namespace from the
cluster's namespaces while still being able to type any name.

## Namespace field

- A text input with a native `<datalist>` of the cluster's namespaces. The
  browser filters suggestions as the user types; any typed value is
  accepted.
- `Beamdash.Kubectl.list_namespaces(kubeconfig, exec \\ &run_kubectl/1)`
  runs `kubectl [--kubeconfig K] get namespaces -o
  jsonpath={.items[*].metadata.name}` and returns `{:ok, [name]}` or
  `{:error, {:namespace_list_failed, reason}}` (same shape as
  `list_pods/3`, including the `catch`).
- `BeamdashWeb.Connection` keeps `kube_namespaces` (`[]` by default). It is
  fetched when the Kubernetes method is selected, when the cluster
  changes, and when the kubeconfig directory changes. A failed listing
  (e.g. RBAC forbids it) sets `[]` silently: no error banner, the field is
  plain free text.
- Picking a suggestion lists pods immediately: a small JS hook
  (`NamespacePick`) submits the namespace form when an `input` event is
  not plain typing (`inputType` absent or `insertReplacementText`). Enter
  or the "List pods" button still work for typed names.

## Appearance

- The method switch becomes a segmented control (like `.seg` /
  `.syntax-toggle`) instead of two filled buttons.
- Both methods render inside one bordered, right-aligned panel using a
  label | control grid so labels and controls line up: Direct shows Node,
  Cookie, Connect; Kubernetes shows Cluster, Namespace (+ List pods),
  Pod, Container (only with more than one), Binary, Connect.
- Inputs, selects and buttons share height (32 px), border, radius and
  background. Connect sits at the bottom right; List pods is a secondary
  button. Hints ("No pods found…", "No binaries…", no kubeconfig files)
  show as muted small text in the control column.
- Existing element ids, form events and field names stay the same.

## Tests

- `kubectl_test.exs`: `list_namespaces/2` parses output, passes
  `--kubeconfig`, returns the error tuple on non-zero exit and on raise.
- `connection_bar_test.exs`: the datalist lists namespaces when listing
  succeeds; no datalist and no error when it fails; Direct and Kubernetes
  controls render with their labels.
- Visual check: headless Chrome screenshots of both methods.
