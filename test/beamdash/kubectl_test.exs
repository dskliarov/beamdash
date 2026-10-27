defmodule Beamdash.KubectlTest do
  use ExUnit.Case, async: true

  alias Beamdash.Kubectl
  alias Beamdash.Kubectl.Tunnel

  describe "list_kubeconfigs/1" do
    test "lists .yaml/.yml files, sorted, as {name, path}" do
      dir = tmp_kube_dir()
      File.write!(Path.join(dir, "b-cluster.yaml"), "")
      File.write!(Path.join(dir, "a-cluster.yml"), "")
      File.write!(Path.join(dir, "notes.txt"), "")

      assert {:ok,
              [
                %{name: "a-cluster", path: a_path},
                %{name: "b-cluster", path: b_path}
              ]} = Kubectl.list_kubeconfigs(dir)

      assert a_path == Path.join(dir, "a-cluster.yml")
      assert b_path == Path.join(dir, "b-cluster.yaml")
    end

    test "reports an error for a nonexistent directory" do
      assert {:error, {:kubeconfig_list_failed, :enoent}} =
               Kubectl.list_kubeconfigs(
                 Path.join(
                   System.tmp_dir!(),
                   "does-not-exist-#{System.unique_integer([:positive])}"
                 )
               )
    end
  end

  describe "list_pods/3" do
    test "parses a jsonpath pod list" do
      exec = fn args ->
        assert args == ["get", "pods", "-n", "prod", "-o", "jsonpath={.items[*].metadata.name}"]
        {"my-pod-1 my-pod-2\n", 0}
      end

      assert {:ok, ["my-pod-1", "my-pod-2"]} = Kubectl.list_pods(nil, "prod", exec)
    end

    test "passes --kubeconfig when a cluster is given" do
      exec = fn args ->
        assert args == [
                 "--kubeconfig",
                 "/home/me/.kube/prod.yaml",
                 "get",
                 "pods",
                 "-n",
                 "prod",
                 "-o",
                 "jsonpath={.items[*].metadata.name}"
               ]

        {"my-pod-1\n", 0}
      end

      assert {:ok, ["my-pod-1"]} = Kubectl.list_pods("/home/me/.kube/prod.yaml", "prod", exec)
    end

    test "a non-zero exit is reported" do
      exec = fn _args -> {"namespace not found", 1} end

      assert {:error, {:pod_list_failed, {1, "namespace not found"}}} =
               Kubectl.list_pods(nil, "prod", exec)
    end

    test "an exception from exec is caught and reported" do
      exec = fn _args -> raise "boom" end

      assert {:error, {:pod_list_failed, {:error, %RuntimeError{}}}} =
               Kubectl.list_pods(nil, "prod", exec)
    end
  end

  describe "list_namespaces/2" do
    test "parses a jsonpath namespace list" do
      exec = fn args ->
        assert args == [
                 "--request-timeout=5s",
                 "get",
                 "namespaces",
                 "-o",
                 "jsonpath={.items[*].metadata.name}"
               ]

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
                 "--request-timeout=5s",
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

  describe "list_containers/4" do
    test "parses a jsonpath container list" do
      exec = fn args ->
        assert args == [
                 "get",
                 "pod",
                 "-n",
                 "prod",
                 "my-pod",
                 "-o",
                 "jsonpath={.spec.containers[*].name}"
               ]

        {"gateway debug\n", 0}
      end

      assert {:ok, ["gateway", "debug"]} = Kubectl.list_containers(nil, "prod", "my-pod", exec)
    end

    test "passes --kubeconfig when a cluster is given" do
      exec = fn args ->
        assert args == [
                 "--kubeconfig",
                 "/home/me/.kube/prod.yaml",
                 "get",
                 "pod",
                 "-n",
                 "prod",
                 "my-pod",
                 "-o",
                 "jsonpath={.spec.containers[*].name}"
               ]

        {"gateway\n", 0}
      end

      assert {:ok, ["gateway"]} =
               Kubectl.list_containers("/home/me/.kube/prod.yaml", "prod", "my-pod", exec)
    end

    test "a non-zero exit is reported" do
      exec = fn _args -> {"pod not found", 1} end

      assert {:error, {:container_list_failed, {1, "pod not found"}}} =
               Kubectl.list_containers(nil, "prod", "my-pod", exec)
    end

    test "an exception from exec is caught and reported" do
      exec = fn _args -> raise "boom" end

      assert {:error, {:container_list_failed, {:error, %RuntimeError{}}}} =
               Kubectl.list_containers(nil, "prod", "my-pod", exec)
    end
  end

  describe "list_binaries/5" do
    test "parses `ls -1` output into a sorted list of names" do
      exec = fn args ->
        assert args == ["exec", "-n", "prod", "my-pod", "--", "ls", "-1", "/app/bin"]
        {"my_app\nmy_app.bat\n", 0}
      end

      assert {:ok, ["my_app", "my_app.bat"]} =
               Kubectl.list_binaries(nil, "prod", "my-pod", "", exec)
    end

    test "passes -c container when one is given" do
      exec = fn args ->
        assert args == [
                 "exec",
                 "-n",
                 "prod",
                 "my-pod",
                 "-c",
                 "gateway",
                 "--",
                 "ls",
                 "-1",
                 "/app/bin"
               ]

        {"my_app\n", 0}
      end

      assert {:ok, ["my_app"]} = Kubectl.list_binaries(nil, "prod", "my-pod", "gateway", exec)
    end

    test "passes --kubeconfig when a cluster is given" do
      exec = fn args ->
        assert args == [
                 "--kubeconfig",
                 "/home/me/.kube/prod.yaml",
                 "exec",
                 "-n",
                 "prod",
                 "my-pod",
                 "--",
                 "ls",
                 "-1",
                 "/app/bin"
               ]

        {"my_app\n", 0}
      end

      assert {:ok, ["my_app"]} =
               Kubectl.list_binaries("/home/me/.kube/prod.yaml", "prod", "my-pod", "", exec)
    end

    test "sorts the names" do
      exec = fn _args -> {"zeta\nalpha\n", 0} end
      assert {:ok, ["alpha", "zeta"]} = Kubectl.list_binaries(nil, "prod", "my-pod", "", exec)
    end

    test "a non-zero exit is reported" do
      exec = fn _args -> {"No such file or directory\n", 1} end

      assert {:error, {:binary_list_failed, {1, "No such file or directory"}}} =
               Kubectl.list_binaries(nil, "prod", "my-pod", "", exec)
    end

    test "an exception from exec is caught and reported" do
      exec = fn _args -> raise "boom" end

      assert {:error, {:binary_list_failed, {:error, %RuntimeError{}}}} =
               Kubectl.list_binaries(nil, "prod", "my-pod", "", exec)
    end
  end

  describe "logs_args/5" do
    test "follow without kubeconfig or container" do
      assert Kubectl.logs_args(nil, "prod", "p", nil, follow: true) ==
               ["logs", "-n", "prod", "p", "--timestamps", "--tail=1000", "-f"]
    end

    test "kubeconfig, container and previous" do
      assert Kubectl.logs_args("/k.yaml", "prod", "p", "app", previous: true) ==
               [
                 "--kubeconfig",
                 "/k.yaml",
                 "logs",
                 "-n",
                 "prod",
                 "p",
                 "-c",
                 "app",
                 "--timestamps",
                 "--tail=1000",
                 "--previous"
               ]
    end

    test "an empty container is omitted and no mode adds nothing" do
      assert Kubectl.logs_args(nil, "prod", "p", "", []) ==
               ["logs", "-n", "prod", "p", "--timestamps", "--tail=1000"]
    end
  end

  describe "connect/6 discovery" do
    test "reads node and cookie from an Elixir-style rpc reply" do
      exec = fn
        ["exec", "-n", "prod", "my-pod", "--", "/app/bin/my_app", "rpc", expr] ->
          assert expr == "IO.puts(node()); IO.puts(:erlang.get_cookie())"
          {"app@10.0.0.5\nsecret_cookie\n", 0}
      end

      open_forward = fn _kc, _ns, _pod, {local, _remote} ->
        {:ok, fake_epmd(local, "app", 9999)}
      end

      assert {:ok, %{node: :"app@10.0.0.5", cookie: :secret_cookie, tunnel: %Tunnel{}}} =
               Kubectl.connect(nil, "prod", "my-pod", "", "my_app",
                 exec: exec,
                 open_forward: open_forward
               )
    end

    test "passes -c container to exec when one is given" do
      exec = fn args ->
        assert args == [
                 "exec",
                 "-n",
                 "prod",
                 "my-pod",
                 "-c",
                 "gateway",
                 "--",
                 "/app/bin/my_app",
                 "rpc",
                 "IO.puts(node()); IO.puts(:erlang.get_cookie())"
               ]

        {"app@10.0.0.5\nsecret_cookie\n", 0}
      end

      open_forward = fn _kc, _ns, _pod, {local, _remote} ->
        {:ok, fake_epmd(local, "app", 9999)}
      end

      assert {:ok, %{node: :"app@10.0.0.5", cookie: :secret_cookie}} =
               Kubectl.connect(nil, "prod", "my-pod", "gateway", "my_app",
                 exec: exec,
                 open_forward: open_forward
               )
    end

    test "passes the kubeconfig path through to exec and open_forward" do
      exec = fn args ->
        assert [
                 "--kubeconfig",
                 "/home/me/.kube/prod.yaml"
                 | _
               ] = args

        {"app@10.0.0.5\nsecret_cookie\n", 0}
      end

      open_forward = fn kubeconfig, _ns, _pod, {local, _remote} ->
        assert kubeconfig == "/home/me/.kube/prod.yaml"
        {:ok, fake_epmd(local, "app", 9999)}
      end

      assert {:ok, %{node: :"app@10.0.0.5", cookie: :secret_cookie}} =
               Kubectl.connect("/home/me/.kube/prod.yaml", "prod", "my-pod", "", "my_app",
                 exec: exec,
                 open_forward: open_forward
               )
    end

    test "falls back to an Erlang-style rpc reply when the Elixir one fails" do
      exec = fn
        ["exec", "-n", "prod", "my-pod", "--", "/app/bin/my_app", "rpc", expr] ->
          if String.starts_with?(expr, "IO.puts") do
            {"** (CompileError) undefined function IO", 1}
          else
            assert expr == ~s|io:format("~s~n~s~n",[node(), erlang:get_cookie()]).|
            {"app@10.0.0.5\nsecret_cookie\n", 0}
          end
      end

      open_forward = fn _kc, _ns, _pod, {local, _remote} ->
        {:ok, fake_epmd(local, "app", 9999)}
      end

      assert {:ok, %{node: :"app@10.0.0.5", cookie: :secret_cookie}} =
               Kubectl.connect(nil, "prod", "my-pod", "", "my_app",
                 exec: exec,
                 open_forward: open_forward
               )
    end

    test "reports an error when neither rpc flavor parses" do
      exec = fn _args -> {"not two lines", 0} end

      assert {:error, {:discovery_failed, _}} =
               Kubectl.connect(nil, "prod", "my-pod", "", "my_app",
                 exec: exec,
                 open_forward: fn _, _, _, _ -> flunk("not reached") end
               )
    end

    test "reports an error when kubectl exec itself fails" do
      exec = fn _args -> {"pod not found", 1} end

      assert {:error, {:discovery_failed, _}} =
               Kubectl.connect(nil, "prod", "my-pod", "", "my_app",
                 exec: exec,
                 open_forward: fn _, _, _, _ -> flunk("not reached") end
               )
    end

    test "reports an error when the epmd forward fails" do
      exec = fn _args -> {"app@10.0.0.5\nsecret_cookie\n", 0} end
      open_forward = fn _kc, _ns, _pod, _ports -> {:error, :kubectl_not_found} end

      assert {:error, :kubectl_not_found} =
               Kubectl.connect(nil, "prod", "my-pod", "", "my_app",
                 exec: exec,
                 open_forward: open_forward
               )
    end

    test "reports an error when the discovered node's name is not in the epmd reply" do
      exec = fn _args -> {"app@10.0.0.5\nsecret_cookie\n", 0} end

      open_forward = fn _kc, _ns, _pod, {local, _remote} ->
        {:ok, fake_epmd(local, "other_app", 9999)}
      end

      assert {:error, {:epmd_discovery_failed, {:not_found, "app"}}} =
               Kubectl.connect(nil, "prod", "my-pod", "", "my_app",
                 exec: exec,
                 open_forward: open_forward
               )
    end
  end

  describe "close/1" do
    test "is a no-op for nil" do
      assert :ok = Kubectl.close(nil)
    end
  end

  # A fresh, empty directory under the OS tmp dir, torn down after the test.
  defp tmp_kube_dir do
    dir = Path.join(System.tmp_dir!(), "beamdash-kube-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A minimal fake epmd server bound to `local_port` that replies to one
  # NAMES_REQ with a single "name <name> at port <port>" line, matching the
  # real protocol closely enough for `Kubectl.connect/6`'s own client code.
  defp fake_epmd(local_port, name, dist_port) do
    {:ok, listen} =
      :gen_tcp.listen(local_port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    parent = self()

    spawn(fn ->
      with {:ok, sock} <- :gen_tcp.accept(listen, 5_000),
           {:ok, <<1::16, ?n>>} <- :gen_tcp.recv(sock, 0, 5_000) do
        reply = <<4369::32>> <> "name #{name} at port #{dist_port}\n"
        :gen_tcp.send(sock, reply)
        :gen_tcp.close(sock)
      end

      :gen_tcp.close(listen)
      send(parent, :fake_epmd_done)
    end)

    make_ref()
  end
end
