defmodule Beamdash.NotebookLiveTest do
  use ExUnit.Case, async: false
  alias Beamdash.{Notebook, NotebookStore, Target}
  alias BeamdashWeb.NotebookLive

  setup do
    Target.disconnect()

    dir =
      Path.join(System.tmp_dir!(), "beamdash-notebook-view-#{System.unique_integer([:positive])}")

    old = Application.get_env(:beamdash, :notebooks_dir)
    Application.put_env(:beamdash, :notebooks_dir, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:beamdash, :notebooks_dir, old),
        else: Application.delete_env(:beamdash, :notebooks_dir)

      File.rm_rf(dir)
    end)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = NotebookLive.mount(%{}, %{}, socket)
    %{socket: socket, dir: dir}
  end

  test "edits, saves and reopens a notebook without evaluating code", %{socket: socket, dir: dir} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    {:noreply, edited} =
      NotebookLive.handle_event(
        "edit_cell",
        %{"cell_id" => cell.id, "source" => "x = 21"},
        socket
      )

    assert edited.assigns.dirty

    {:noreply, saved} =
      NotebookLive.handle_event("save_notebook", %{"filename" => "node.livemd"}, edited)

    refute saved.assigns.dirty
    assert {:ok, source, _} = NotebookStore.load("node.livemd", dir)
    assert source =~ "x = 21"

    {:noreply, opened} =
      NotebookLive.handle_event("open_notebook", %{"name" => "node.livemd"}, saved)

    assert Notebook.to_livemd(opened.assigns.notebook) == source
    assert opened.assigns.sessions == %{}
    assert opened.assigns.pending == nil
    html = opened.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Download .livemd"
    assert html =~ "Run all"
  end

  test "disconnect preserves unsaved content and rejects cell execution", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    {:noreply, socket} =
      NotebookLive.handle_event(
        "edit_cell",
        %{"cell_id" => cell.id, "source" => "important draft"},
        socket
      )

    {:noreply, disconnected} =
      NotebookLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)

    assert Notebook.to_livemd(disconnected.assigns.notebook) =~ "important draft"
    {:noreply, socket} = NotebookLive.handle_event("run_cell", %{"id" => cell.id}, disconnected)
    assert socket.assigns.error =~ "Connect"
    assert socket.assigns.sessions == %{}
  end

  test "a cleared Markdown cell remains editable and accepts replacement text", %{socket: socket} do
    {:noreply, socket} = NotebookLive.handle_event("add_cell", %{"kind" => "markdown"}, socket)

    cell =
      Enum.find(
        socket.assigns.notebook.blocks,
        &String.contains?(&1.source, "Write Markdown here.")
      )

    {:noreply, socket} =
      NotebookLive.handle_event("edit_cell", %{"cell_id" => cell.id, "source" => ""}, socket)

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(id="notebook-block-#{cell.id}")
    assert html =~ ~s(id="notebook-markdown-#{cell.id}")

    {:noreply, socket} =
      NotebookLive.handle_event(
        "edit_cell",
        %{"cell_id" => cell.id, "source" => "Replacement text"},
        socket
      )

    assert Enum.find(socket.assigns.notebook.blocks, &(&1.id == cell.id)).source ==
             "Replacement text"

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Replacement text"
  end

  test "an error stops run-all and stale async responses are ignored", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)
    ref = make_ref()
    socket = Phoenix.Component.assign(socket, pending: %{id: cell.id, ref: ref}, queue: ["next"])

    {:noreply, socket} =
      NotebookLive.handle_async(
        {:notebook_cell, ref},
        {:ok, {:ok, %{status: :error, output: "", result: "failed"}}},
        socket
      )

    assert socket.assigns.queue == []
    assert socket.assigns.results[cell.id].status == :error

    {:noreply, after_stale} =
      NotebookLive.handle_async(
        {:notebook_cell, ref},
        {:ok, {:ok, %{status: :ok, output: "", result: "wrong"}}},
        socket
      )

    assert after_stale.assigns.results[cell.id].result == "failed"
  end
end
