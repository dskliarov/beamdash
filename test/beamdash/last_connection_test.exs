defmodule Beamdash.LastConnectionTest do
  use ExUnit.Case, async: false

  alias Beamdash.{LastConnection, Settings}

  setup do
    :ok = LastConnection.forget()
    :ok = Settings.put_multiple_connections(false)

    on_exit(fn ->
      Settings.put_multiple_connections(false)
      LastConnection.forget()
    end)

    :ok
  end

  defp node_entry(name), do: %{"kind" => "node", "node" => name, "cookie" => ""}

  defp kubectl_entry(name, app) do
    %{
      "kind" => "kubectl",
      "node" => name,
      "cookie" => "",
      "app" => app,
      "kubeconfig" => "",
      "namespace" => "pace",
      "pod" => name,
      "container" => "",
      "binary" => ""
    }
  end

  describe "app" do
    test "a node entry's app is the node name prefix before @" do
      :ok = LastConnection.put(node_entry("api@web-1"))

      assert [%{"app" => "api"}] = LastConnection.list()
    end

    test "a kubectl entry keeps the app it was saved with" do
      :ok = LastConnection.put(kubectl_entry("api-0@pace", "registry:5000/team/api"))

      assert [%{"app" => "registry:5000/team/api"}] = LastConnection.list()
    end

    test "a kubectl entry saved without an image has an empty app" do
      :ok = LastConnection.put(kubectl_entry("api-0@pace", ""))

      assert [%{"app" => ""}] = LastConnection.list()
    end

    test "an entry from a file written before the app field gets its app on read" do
      path = LastConnection.path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"connections" => [node_entry("api@web-1")]}))
      :ok = LastConnection.reload()

      assert [%{"node" => "api@web-1", "app" => "api"}] = LastConnection.list()
    end
  end

  describe "cap" do
    test "keeps ten entries while multiple connections are off" do
      for i <- 1..12, do: :ok = LastConnection.put(node_entry("api@web-#{i}"))

      assert length(LastConnection.list()) == 10
      assert [%{"node" => "api@web-12"} | _] = LastConnection.list()
    end

    test "keeps thirty entries while multiple connections are on" do
      :ok = Settings.put_multiple_connections(true)

      for i <- 1..32, do: :ok = LastConnection.put(node_entry("api@web-#{i}"))

      assert length(LastConnection.list()) == 30
    end

    test "turning the setting off keeps the entries until the next save" do
      :ok = Settings.put_multiple_connections(true)
      for i <- 1..25, do: :ok = LastConnection.put(node_entry("api@web-#{i}"))

      :ok = Settings.put_multiple_connections(false)
      :ok = LastConnection.reload()
      assert length(LastConnection.list()) == 25

      :ok = LastConnection.put(node_entry("api@web-26"))
      assert length(LastConnection.list()) == 10
    end
  end
end
