defmodule Beamdash.ModuleEditorTest do
  use ExUnit.Case, async: false

  test "compiles Erlang source without loading it" do
    source = "-module(beamdash_editor_test_module).\n-export([value/0]).\nvalue() -> changed.\n"

    assert {:ok, :beamdash_editor_test_module, beam, _warnings} =
             Beamdash.ModuleEditor.compile(source)

    assert is_binary(beam)
    assert :code.is_loaded(:beamdash_editor_test_module) == false
  end

  test "reports compiler errors" do
    assert {:error, _} = Beamdash.ModuleEditor.compile("not valid Erlang")
  end

  test "the Modules page warns that source and BEAM can differ from running code" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    html =
      socket.assigns
      |> Map.merge(%{syntax: :erlang, status: :connected})
      |> BeamdashWeb.ModulesLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "source and the BEAM file on the server may differ from the running code"
  end

  test "backs up, deploys and restores the running module" do
    mod = :beamdash_editor_deploy_fixture

    original =
      "-module(beamdash_editor_deploy_fixture).\n-export([value/0]).\nvalue() -> original.\n"

    updated = String.replace(original, "original", "updated")
    {:ok, ^mod, old_beam, _} = Beamdash.ModuleEditor.compile(original)
    {:ok, ^mod, new_beam, _} = Beamdash.ModuleEditor.compile(updated)
    dir = Path.join(System.tmp_dir!(), "beamdash-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{mod}.beam"), old_beam)
    :code.add_patha(String.to_charlist(dir))
    {:module, ^mod} = :code.load_abs(String.to_charlist(Path.join(dir, Atom.to_string(mod))))

    try do
      assert {:ok, backup} = Beamdash.ModuleEditor.backup(node(), mod)
      assert {:ok, digest} = Beamdash.ModuleEditor.load(node(), mod, new_beam, backup.digest)
      assert apply(mod, :value, []) == :updated
      assert {:error, _} = Beamdash.ModuleEditor.load(node(), mod, old_beam, backup.digest)
      assert {:ok, _} = Beamdash.ModuleEditor.load(node(), mod, backup.beam, digest)
      assert apply(mod, :value, []) == :original
    after
      :code.purge(mod)
      :code.delete(mod)
      :code.del_path(String.to_charlist(dir))
      File.rm_rf!(dir)
    end
  end

  test "rejects overlapping beamdash deployments and detects a changed running module" do
    mod = :beamdash_editor_race_fixture
    source = "-module(beamdash_editor_race_fixture).\n-export([value/0]).\nvalue() -> original.\n"
    {:ok, ^mod, original, _} = Beamdash.ModuleEditor.compile(source)

    {:ok, ^mod, changed, _} =
      Beamdash.ModuleEditor.compile(String.replace(source, "original", "changed"))

    {:ok, {^mod, digest}} = :beam_lib.md5(original)
    {:module, ^mod} = :code.load_binary(mod, ~c"original", original)
    parent = self()

    holder =
      spawn(fn ->
        id = {{:beamdash_module_deploy, mod}, self()}
        true = :global.set_lock(id, [node()], 0)
        send(parent, :locked)

        receive do
          :release -> :global.del_lock(id, [node()])
        end

        send(parent, :released)
      end)

    try do
      assert_receive :locked
      assert {:error, message} = Beamdash.ModuleEditor.load(node(), mod, changed, digest)
      assert message =~ "another beamdash deployment"
      assert apply(mod, :value, []) == :original
      send(holder, :release)
      assert_receive :released
      {:module, ^mod} = :code.load_binary(mod, ~c"external", changed)
      assert {:error, _} = Beamdash.ModuleEditor.load(node(), mod, original, digest)
      assert apply(mod, :value, []) == :changed
    after
      send(holder, :release)
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  test "loads the deployment coordinator on the connected node" do
    {peer, target} = Beamdash.Test.Fixture.start_peer()
    on_exit(fn -> Beamdash.Test.Fixture.stop_peer(peer) end)
    {:ok, _} = Beamdash.Target.connect(Atom.to_string(target), Beamdash.Test.Fixture.cookie())
    on_exit(fn -> Beamdash.Target.disconnect() end)
    mod = :beamdash_remote_deploy_fixture

    source =
      "-module(beamdash_remote_deploy_fixture).\n-export([value/0]).\nvalue() -> original.\n"

    {:ok, ^mod, original, _} = Beamdash.ModuleEditor.compile(source)

    {:ok, ^mod, changed, _} =
      Beamdash.ModuleEditor.compile(String.replace(source, "original", "changed"))

    {:ok, {^mod, digest}} = :beam_lib.md5(original)

    assert {:module, ^mod} =
             :erpc.call(target, :code, :load_binary, [mod, ~c"original", original])

    assert {:ok, _} = Beamdash.ModuleEditor.load(target, mod, changed, digest)
    assert :changed = :erpc.call(target, mod, :value, [])
    assert :erpc.call(target, :code, :is_loaded, [:beamdash_module_deploy]) != false
  end

  test "compiles Elixir in a separate VM without loading it into the dashboard" do
    mod = BeamdashEditorIsolatedFixture
    source = "defmodule BeamdashEditorIsolatedFixture do\n  def value, do: :ok\nend"
    assert {:ok, ^mod, beam, _} = Beamdash.ModuleEditor.compile_elixir(source, mod)
    assert is_binary(beam)
    assert :code.is_loaded(mod) == false
  end

  test "rejects extra modules emitted by Elixir source" do
    source =
      "defmodule BeamdashEditorIsolatedFixture do end\ndefmodule BeamdashEditorExtra do end"

    assert {:error, _} =
             Beamdash.ModuleEditor.compile_elixir(source, BeamdashEditorIsolatedFixture)

    assert :code.is_loaded(BeamdashEditorExtra) == false
  end

  test "reports Elixir compilation errors" do
    assert {:error, _} =
             Beamdash.ModuleEditor.compile_elixir(
               "defmodule Broken do",
               BeamdashEditorIsolatedFixture
             )
  end

  test "uses compile-time configuration from a local Mix project" do
    dir = Path.join(System.tmp_dir!(), "beamdash-mix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "config"))

    File.write!(
      Path.join(dir, "mix.exs"),
      "defmodule Fixture.MixProject do\n use Mix.Project\n def project, do: [app: :editor_fixture, version: \"0.1.0\"]\nend\n"
    )

    File.write!(
      Path.join(dir, "config/config.exs"),
      "import Config\nconfig :editor_fixture, :value, :from_project\n"
    )

    source =
      "defmodule BeamdashEditorIsolatedFixture do\n @value Application.compile_env(:editor_fixture, :value)\n def value, do: @value\nend"

    try do
      assert {:ok, BeamdashEditorIsolatedFixture, beam, _} =
               Beamdash.ModuleEditor.compile_elixir(source, BeamdashEditorIsolatedFixture,
                 project: dir
               )

      assert {:ok, {BeamdashEditorIsolatedFixture, _}} = :beam_lib.md5(beam)
    after
      File.rm_rf!(dir)
    end
  end

  test "tests staged code in a separate VM without loading it here" do
    source = "-module(beamdash_candidate_fixture).\n-export([add/2]).\nadd(A, B) -> A + B.\n"
    {:ok, mod, beam, _} = Beamdash.ModuleEditor.compile(source)
    assert {:ok, result, _log} = Beamdash.ModuleEditor.test_candidate(mod, beam, "add", "[2, 3]")
    assert result == "5"
    assert :code.is_loaded(mod) == false
  end

  test "reports invalid arguments and function exceptions in candidate tests" do
    source =
      "-module(beamdash_candidate_fixture).\n-export([fail/0]).\nfail() -> error(test_failure).\n"

    {:ok, mod, beam, _} = Beamdash.ModuleEditor.compile(source)
    assert {:error, _} = Beamdash.ModuleEditor.test_candidate(mod, beam, "fail", "invalid")
    assert {:error, message} = Beamdash.ModuleEditor.test_candidate(mod, beam, "fail", "[]")
    assert message =~ "test_failure"
  end

  test "the staged test is optional and reports the candidate result" do
    source = "-module(beamdash_candidate_fixture).\n-export([value/0]).\nvalue() -> staged.\n"
    {:ok, mod, beam, _} = Beamdash.ModuleEditor.compile(source)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        node: node(),
        selected: mod,
        compiled: beam
      )

    html =
      socket.assigns
      |> Map.put(:syntax, :erlang)
      |> BeamdashWeb.ModulesLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "Test candidate before deployment (optional)"
    assert html =~ ~s(phx-click="deploy")

    {:noreply, socket} =
      BeamdashWeb.ModulesLive.handle_event(
        "test_candidate",
        %{"function" => "value", "arguments" => "[]"},
        socket
      )

    assert socket.assigns.candidate_result =~ "staged"
    assert socket.assigns.compiled == beam
  end

  test "module list filters names without changing the staged editor" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        modules: [:lists, :maps],
        selected: :maps,
        source: "draft",
        compiled: "candidate"
      )

    {:noreply, filtered} =
      BeamdashWeb.ModulesLive.handle_event("filter_modules", %{"q" => " LIST "}, socket)

    assert filtered.assigns.module_filter == " LIST "
    assert filtered.assigns.selected == :maps
    assert filtered.assigns.source == "draft"
    assert filtered.assigns.compiled == "candidate"

    html =
      filtered.assigns
      |> Map.put(:syntax, :erlang)
      |> BeamdashWeb.ModulesLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ ~s(phx-value-module="lists")
    refute html =~ ~s(phx-value-module="maps")
    assert html =~ "1 of 2 loaded modules"
    refute html =~ ~s(select name="module")
  end

  test "module list shows an empty result and keeps selection locked during rollback" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        modules: [:lists],
        backup: %{beam: "saved"}
      )

    {:noreply, unchanged} =
      BeamdashWeb.ModulesLive.handle_event("select", %{"module" => "lists"}, socket)

    assert unchanged.assigns.selected == nil

    {:noreply, filtered} =
      BeamdashWeb.ModulesLive.handle_event("filter_modules", %{"q" => "no-match"}, socket)

    html =
      filtered.assigns
      |> Map.put(:syntax, :erlang)
      |> BeamdashWeb.ModulesLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "No matching modules"
  end

  test "clear and discard invalidate the candidate and preserve rollback" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)
    original = %{source: "original code", language: "elixir", project: "/project"}

    socket =
      Phoenix.Component.assign(socket,
        selected: Demo,
        original: original,
        source: "edited code",
        language: "erlang",
        project: "/other",
        compiled: "beam",
        candidate_result: "passed",
        backup: %{beam: "backup"}
      )

    {:noreply, cleared} = BeamdashWeb.ModulesLive.handle_event("clear_source", %{}, socket)
    assert cleared.assigns.source == ""
    assert cleared.assigns.editor_revision == socket.assigns.editor_revision + 1
    assert cleared.assigns.compiled == nil
    assert cleared.assigns.candidate_result == nil
    assert cleared.assigns.original == original
    {:noreply, discarded} = BeamdashWeb.ModulesLive.handle_event("discard_source", %{}, cleared)
    assert discarded.assigns.source == original.source
    assert discarded.assigns.editor_revision == socket.assigns.editor_revision + 2
    assert discarded.assigns.language == original.language
    assert discarded.assigns.project == original.project
    assert discarded.assigns.backup == socket.assigns.backup
  end
end
