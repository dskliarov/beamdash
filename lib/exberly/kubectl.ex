defmodule Exberly.Kubectl do
  @moduledoc """
  Connects to a node running in a Kubernetes pod, when it is not reachable
  the way `Exberly.Target`'s direct connect expects (the node's advertised
  address is normally its pod IP, which `kubectl port-forward` does not make
  routable, since Erlang distribution connects to that address directly
  rather than doing a hostname lookup).

  Given a namespace, a pod, the container to run commands in (`list_containers/2`
  lists them; pods with more than one container otherwise default to
  whichever `kubectl exec` picks, which is not necessarily the one running
  the release) and a release binary under `/app/bin` in it (`list_binaries/3`
  lists them), `connect/5`:

    1. reads the node name and distribution cookie off the pod with
       `kubectl exec ... <binary> rpc "..."`, which goes through the
       Kubernetes API server rather than node distribution, so it needs no
       tunnel and works before one exists;
    2. forwards epmd (`kubectl port-forward ... <local>:4369`) to discover
       the node's distribution port;
    3. forwards that distribution port the same way;
    4. installs `:exberly_epmd` (`src/exberly_epmd.erl`) as this VM's EPMD
       discovery module (see ERTS "Alternative Node Discovery") and points
       it, through a `persistent_term`, at the local tunnel for this one
       node name, so `Exberly.Target`'s own `hidden_connect_node/1` reaches
       it over the tunnel instead of trying the pod's real address.

  `close/1` tears the tunnel down: kills both `kubectl port-forward`
  processes (`Port.close/1` alone would leave them running, since kubectl
  does not notice its stdin pipe closing) and clears the persistent_term
  target, so `:exberly_epmd` falls back to normal lookups.

  `Exberly.Target` owns the connect/disconnect lifecycle; this module only
  knows how to open and close one tunnel.
  """

  @epmd_target_key {:exberly_epmd, :target}
  @epmd_port 4369
  @release_bin_dir "/app/bin"
  @forward_wait_attempts 40
  @forward_wait_interval 500

  defmodule Tunnel do
    @moduledoc false
    defstruct [:epmd_port, :dist_port]
  end

  @doc """
  Containers in `pod` (`connect/5` and `list_binaries/4` need one to pick
  which container `kubectl exec` runs in; pods with a single container
  don't need this at all, `kubectl exec` defaults to it on its own).
  """
  @spec list_containers(String.t(), String.t(), (list(String.t()) -> {binary(), integer()})) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_containers(namespace, pod, exec \\ &run_kubectl/1) do
    case exec.([
           "get",
           "pod",
           "-n",
           namespace,
           pod,
           "-o",
           "jsonpath={.spec.containers[*].name}"
         ]) do
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
  name there is a good guess at the binary to pick for `connect/5`).
  """
  @spec list_binaries(String.t(), String.t(), String.t(), (list(String.t()) -> {binary(), integer()})) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_binaries(namespace, pod, container, exec \\ &run_kubectl/1) do
    case exec.(exec_args(namespace, pod, container, ["ls", "-1", @release_bin_dir])) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.sort()}

      {output, status} ->
        {:error, {:binary_list_failed, {status, String.trim(output)}}}
    end
  catch
    kind, reason -> {:error, {:binary_list_failed, {kind, reason}}}
  end

  @doc """
  Opens a tunnel to `pod`'s `container` in `namespace` through `binary` (a
  path under #{@release_bin_dir}) and returns the node and cookie
  discovered there, with the tunnel to pass to `Target.connect/2` and
  later to `close/1`.
  """
  @spec connect(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{node: node(), cookie: atom(), tunnel: %Tunnel{}}} | {:error, term()}
  def connect(namespace, pod, container, binary, opts \\ []) do
    exec = Keyword.get(opts, :exec, &run_kubectl/1)
    open_forward = Keyword.get(opts, :open_forward, &open_port_forward/3)

    with {:ok, {node, cookie}} <- discover(namespace, pod, container, binary, exec),
         [short_name, _host] <- String.split(Atom.to_string(node), "@", parts: 2),
         {:ok, epmd_local} <- free_local_port(),
         {:ok, epmd_forward} <- open_forward.(namespace, pod, {epmd_local, @epmd_port}),
         {:ok, dist_port} <- discover_dist_port(epmd_local, short_name),
         {:ok, dist_local} <- free_local_port(),
         {:ok, dist_forward} <- open_forward.(namespace, pod, {dist_local, dist_port}) do
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

  @doc "Closes both port-forwards opened by `connect/5` and forgets the tunnel target."
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

  defp discover(namespace, pod, container, binary, exec) do
    release_bin = Path.join(@release_bin_dir, binary)

    with {:error, elixir_reason} <-
           discover_with(namespace, pod, container, release_bin, :elixir, exec),
         {:error, erlang_reason} <-
           discover_with(namespace, pod, container, release_bin, :erlang, exec) do
      {:error, {:discovery_failed, {elixir_reason, erlang_reason}}}
    end
  end

  defp discover_with(namespace, pod, container, release_bin, flavor, exec) do
    args = exec_args(namespace, pod, container, [release_bin, "rpc", rpc_expr(flavor)])

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
           :gen_tcp.connect(~c"127.0.0.1", local_epmd_port, [:binary, active: false, packet: 0], 5_000),
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

  defp open_port_forward(namespace, pod, {local_port, remote_port}) do
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
              args: [
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
      :exberly_epmd -> :ok
      _ -> Application.put_env(:kernel, :epmd_module, :exberly_epmd)
    end
  end

  defp persistent_term_put(short_name, local_dist_port) do
    :persistent_term.put(@epmd_target_key, {String.to_charlist(short_name), local_dist_port})
  end

  ## Helpers

  # `-c container` only when one is given: a single-container pod needs
  # none, `kubectl exec` already defaults to its one container.
  defp exec_args(namespace, pod, container, command) do
    base = ["exec", "-n", namespace, pod]
    with_container = if container in [nil, ""], do: base, else: base ++ ["-c", container]
    with_container ++ ["--"] ++ command
  end

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
