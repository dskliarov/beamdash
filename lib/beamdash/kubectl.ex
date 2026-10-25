defmodule Beamdash.Kubectl do
  @moduledoc """
  Connects to a node running in a Kubernetes pod, when it is not reachable
  the way `Beamdash.Target`'s direct connect expects (the node's advertised
  address is normally its pod IP, which `kubectl port-forward` does not make
  routable, since Erlang distribution connects to that address directly
  rather than doing a hostname lookup).

  Given a cluster (a kubeconfig file, see `list_kubeconfigs/1`), a
  namespace, a pod, the container to run commands in (`list_containers/4`
  lists them; pods with more than one container otherwise default to
  whichever `kubectl exec` picks, which is not necessarily the one running
  the release) and a release binary under `/app/bin` in it (`list_binaries/5`
  lists them), `connect/6`:

    1. reads the node name and distribution cookie off the pod with
       `kubectl exec ... <binary> rpc "..."`, which goes through the
       Kubernetes API server rather than node distribution, so it needs no
       tunnel and works before one exists;
    2. forwards epmd (`kubectl port-forward ... <local>:4369`) to discover
       the node's distribution port;
    3. forwards that distribution port the same way;
    4. installs `:beamdash_epmd` (`src/beamdash_epmd.erl`) as this VM's EPMD
       discovery module (see ERTS "Alternative Node Discovery") and points
       it, through a `persistent_term`, at the local tunnel for this one
       node name, so `Beamdash.Target`'s own `hidden_connect_node/1` reaches
       it over the tunnel instead of trying the pod's real address.

  `close/1` tears the tunnel down: kills both `kubectl port-forward`
  processes (`Port.close/1` alone would leave them running, since kubectl
  does not notice its stdin pipe closing) and clears the persistent_term
  target, so `:beamdash_epmd` falls back to normal lookups.

  `Beamdash.Target` owns the connect/disconnect lifecycle; this module only
  knows how to open and close one tunnel.
  """

  @epmd_target_key {:beamdash_epmd, :target}
  @epmd_port 4369
  @release_bin_dir "/app/bin"
  @forward_wait_attempts 40
  @forward_wait_interval 500

  defmodule Tunnel do
    @moduledoc false
    defstruct [:epmd_port, :dist_port]
  end

  @doc """
  Kubeconfig files under `dir` (default `Beamdash.Settings.kubeconfig_dir/0`,
  `~/.kube` unless changed in Settings), one per cluster, so the UI can
  offer a cluster picker instead of relying on an externally-set
  KUBECONFIG/current-context.
  """
  @spec list_kubeconfigs(String.t()) ::
          {:ok, [%{name: String.t(), path: String.t()}]} | {:error, term()}
  def list_kubeconfigs(dir \\ Beamdash.Settings.kubeconfig_dir()) do
    case File.ls(dir) do
      {:ok, files} ->
        {:ok,
         files
         |> Enum.filter(&String.ends_with?(&1, [".yaml", ".yml"]))
         |> Enum.sort()
         |> Enum.map(&%{name: Path.rootname(&1), path: Path.join(dir, &1)})}

      {:error, reason} ->
        {:error, {:kubeconfig_list_failed, reason}}
    end
  end

  @doc """
  Pods in `namespace`, so the user can pick one from a list instead of
  typing it.
  """
  @spec list_pods(String.t() | nil, String.t(), (list(String.t()) -> {binary(), integer()})) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_pods(kubeconfig, namespace, exec \\ &run_kubectl/1) do
    args =
      kubeconfig_args(kubeconfig) ++
        ["get", "pods", "-n", namespace, "-o", "jsonpath={.items[*].metadata.name}"]

    case exec.(args) do
      {output, 0} ->
        {:ok, output |> String.trim() |> String.split(~r/\s+/, trim: true)}

      {output, status} ->
        {:error, {:pod_list_failed, {status, String.trim(output)}}}
    end
  catch
    kind, reason -> {:error, {:pod_list_failed, {kind, reason}}}
  end

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
        [
          "--request-timeout=5s",
          "get",
          "namespaces",
          "-o",
          "jsonpath={.items[*].metadata.name}"
        ]

    case exec.(args) do
      {output, 0} ->
        {:ok, output |> String.trim() |> String.split(~r/\s+/, trim: true)}

      {output, status} ->
        {:error, {:namespace_list_failed, {status, String.trim(output)}}}
    end
  catch
    kind, reason -> {:error, {:namespace_list_failed, {kind, reason}}}
  end

  @doc """
  Containers in `pod` (`connect/6` and `list_binaries/5` need one to pick
  which container `kubectl exec` runs in; pods with a single container
  don't need this at all, `kubectl exec` defaults to it on its own).
  """
  @spec list_containers(
          String.t() | nil,
          String.t(),
          String.t(),
          (list(String.t()) -> {binary(), integer()})
        ) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_containers(kubeconfig, namespace, pod, exec \\ &run_kubectl/1) do
    args =
      kubeconfig_args(kubeconfig) ++
        [
          "get",
          "pod",
          "-n",
          namespace,
          pod,
          "-o",
          "jsonpath={.spec.containers[*].name}"
        ]

    case exec.(args) do
      {output, 0} ->
        {:ok, output |> String.trim() |> String.split(~r/\s+/, trim: true)}

      {output, status} ->
        {:error, {:container_list_failed, {status, String.trim(output)}}}
    end
  catch
    kind, reason -> {:error, {:container_list_failed, {kind, reason}}}
  end

  @doc """
  Binaries under #{@release_bin_dir} in `pod`'s `container` (a release's
  name there is a good guess at the binary to pick for `connect/6`).
  """
  @spec list_binaries(
          String.t() | nil,
          String.t(),
          String.t(),
          String.t(),
          (list(String.t()) -> {binary(), integer()})
        ) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_binaries(kubeconfig, namespace, pod, container, exec \\ &run_kubectl/1) do
    case exec.(exec_args(kubeconfig, namespace, pod, container, ["ls", "-1", @release_bin_dir])) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.sort()}

      {output, status} ->
        {:error, {:binary_list_failed, {status, String.trim(output)}}}
    end
  catch
    kind, reason -> {:error, {:binary_list_failed, {kind, reason}}}
  end

  @doc """
  The `kubectl logs` arguments for `pod`'s `container` in `namespace`: the last
  1000 timestamped lines, plus `-f` when `opts[:follow]` or `--previous` when
  `opts[:previous]` (the previous container instance's log).
  """
  @spec logs_args(String.t() | nil, String.t(), String.t(), String.t() | nil, keyword()) ::
          [String.t()]
  def logs_args(kubeconfig, namespace, pod, container, opts) do
    container_args = if container in [nil, ""], do: [], else: ["-c", container]

    mode =
      cond do
        opts[:follow] -> ["-f"]
        opts[:previous] -> ["--previous"]
        true -> []
      end

    kubeconfig_args(kubeconfig) ++
      ["logs", "-n", namespace, pod] ++
      container_args ++ ["--timestamps", "--tail=1000"] ++ mode
  end

  @doc """
  Opens a tunnel to `pod`'s `container` in `namespace` (in the cluster
  `kubeconfig` points at) through `binary` (a path under
  #{@release_bin_dir}) and returns the node and cookie discovered there,
  with the tunnel to pass to `Target.connect/2` and later to `close/1`.
  """
  @spec connect(String.t() | nil, String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{node: node(), cookie: atom(), tunnel: %Tunnel{}}} | {:error, term()}
  def connect(kubeconfig, namespace, pod, container, binary, opts \\ []) do
    exec = Keyword.get(opts, :exec, &run_kubectl/1)
    open_forward = Keyword.get(opts, :open_forward, &open_port_forward/4)

    with {:ok, {node, cookie}} <- discover(kubeconfig, namespace, pod, container, binary, exec),
         [short_name, _host] <- String.split(Atom.to_string(node), "@", parts: 2),
         {:ok, epmd_local} <- free_local_port(),
         {:ok, epmd_forward} <-
           open_forward.(kubeconfig, namespace, pod, {epmd_local, @epmd_port}),
         {:ok, dist_port} <- discover_dist_port(epmd_local, short_name),
         {:ok, dist_local} <- free_local_port(),
         {:ok, dist_forward} <- open_forward.(kubeconfig, namespace, pod, {dist_local, dist_port}) do
      install_epmd_module()
      persistent_term_put(short_name, dist_local)

      {:ok,
       %{
         node: node,
         cookie: cookie,
         tunnel: %Tunnel{epmd_port: epmd_forward, dist_port: dist_forward}
       }}
    else
      {:error, _} = error ->
        error

      other ->
        {:error, {:discovery_failed, other}}
    end
  end

  @doc "Closes both port-forwards opened by `connect/6` and forgets the tunnel target."
  @spec close(%Tunnel{} | nil) :: :ok
  def close(nil), do: :ok

  def close(%Tunnel{epmd_port: epmd_port, dist_port: dist_port}) do
    close_port_forward(epmd_port)
    close_port_forward(dist_port)
    :persistent_term.erase(@epmd_target_key)
    :ok
  catch
    _, _ -> :ok
  end

  ## Discovery (kubectl exec ... rpc), no tunnel needed

  defp discover(kubeconfig, namespace, pod, container, binary, exec) do
    release_bin = Path.join(@release_bin_dir, binary)

    with {:error, elixir_reason} <-
           discover_with(kubeconfig, namespace, pod, container, release_bin, :elixir, exec),
         {:error, erlang_reason} <-
           discover_with(kubeconfig, namespace, pod, container, release_bin, :erlang, exec) do
      {:error, {:discovery_failed, {elixir_reason, erlang_reason}}}
    end
  end

  defp discover_with(kubeconfig, namespace, pod, container, release_bin, flavor, exec) do
    args =
      exec_args(kubeconfig, namespace, pod, container, [release_bin, "rpc", rpc_expr(flavor)])

    case exec.(args) do
      {output, 0} -> parse_discovery(output)
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp rpc_expr(:elixir), do: "IO.puts(node()); IO.puts(:erlang.get_cookie())"
  defp rpc_expr(:erlang), do: ~s|io:format("~s~n~s~n",[node(), erlang:get_cookie()]).|

  defp parse_discovery(output) do
    case output |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1) do
      [node_str, cookie_str] when node_str != "" and cookie_str != "" ->
        {:ok, {String.to_atom(node_str), String.to_atom(cookie_str)}}

      _ ->
        {:error, {:unparseable_output, output}}
    end
  end

  ## epmd NAMES_REQ (minimal client: 2-byte length + opcode request, the
  ## reply is a 4-byte epmd port then "name <name> at port <port>\n" lines)

  defp discover_dist_port(local_epmd_port, short_name) do
    with {:ok, sock} <-
           :gen_tcp.connect(
             ~c"127.0.0.1",
             local_epmd_port,
             [:binary, active: false, packet: 0],
             5_000
           ),
         :ok <- :gen_tcp.send(sock, <<1::16, ?n>>),
         {:ok, resp} <- :gen_tcp.recv(sock, 0, 5_000) do
      :gen_tcp.close(sock)
      parse_epmd_names(resp, short_name)
    else
      {:error, reason} -> {:error, {:epmd_discovery_failed, reason}}
    end
  end

  defp parse_epmd_names(<<_epmd_port::32, rest::binary>>, short_name) do
    ports =
      rest
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^name (\S+) at port (\d+)/, line) do
          [_, ^short_name, port_str] -> [String.to_integer(port_str)]
          _ -> []
        end
      end)

    case ports do
      [port | _] -> {:ok, port}
      [] -> {:error, {:epmd_discovery_failed, {:not_found, short_name}}}
    end
  end

  ## kubectl port-forward (kept open until `close/1`)

  defp open_port_forward(kubeconfig, namespace, pod, {local_port, remote_port}) do
    case System.find_executable("kubectl") do
      nil ->
        {:error, :kubectl_not_found}

      kubectl ->
        port =
          Port.open(
            {:spawn_executable, kubectl},
            [
              :binary,
              :exit_status,
              args:
                kubeconfig_args(kubeconfig) ++
                  [
                    "port-forward",
                    "-n",
                    namespace,
                    "pod/#{pod}",
                    "#{local_port}:#{remote_port}"
                  ]
            ]
          )

        case wait_until_forwarding(port) do
          :ok -> {:ok, port}
          {:error, reason} -> {:error, {:port_forward_failed, reason}}
        end
    end
  end

  defp wait_until_forwarding(port, attempts \\ @forward_wait_attempts) do
    receive do
      {^port, {:data, data}} ->
        if String.contains?(data, "Forwarding from") do
          :ok
        else
          wait_until_forwarding(port, attempts)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:kubectl_exited, status}}
    after
      @forward_wait_interval ->
        if attempts > 0 do
          wait_until_forwarding(port, attempts - 1)
        else
          Port.close(port)
          {:error, :timeout}
        end
    end
  end

  defp close_port_forward(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", [Integer.to_string(os_pid)])
      nil -> :ok
    end

    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  ## EPMD module installation + target

  defp install_epmd_module do
    case Application.get_env(:kernel, :epmd_module) do
      :beamdash_epmd -> :ok
      _ -> Application.put_env(:kernel, :epmd_module, :beamdash_epmd)
    end
  end

  defp persistent_term_put(short_name, local_dist_port) do
    :persistent_term.put(@epmd_target_key, {String.to_charlist(short_name), local_dist_port})
  end

  ## Helpers

  # `-c container` only when one is given: a single-container pod needs
  # none, `kubectl exec` already defaults to its one container.
  defp exec_args(kubeconfig, namespace, pod, container, command) do
    base = kubeconfig_args(kubeconfig) ++ ["exec", "-n", namespace, pod]
    with_container = if container in [nil, ""], do: base, else: base ++ ["-c", container]
    with_container ++ ["--"] ++ command
  end

  defp kubeconfig_args(nil), do: []
  defp kubeconfig_args(""), do: []
  defp kubeconfig_args(path), do: ["--kubeconfig", path]

  defp free_local_port do
    with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]),
         {:ok, port} <- :inet.port(socket) do
      :gen_tcp.close(socket)
      {:ok, port}
    else
      {:error, reason} -> {:error, {:port_forward_failed, reason}}
    end
  end

  defp run_kubectl(args) do
    case System.find_executable("kubectl") do
      nil -> {"kubectl not found on PATH", 127}
      kubectl -> System.cmd(kubectl, args, stderr_to_stdout: true)
    end
  end
end
