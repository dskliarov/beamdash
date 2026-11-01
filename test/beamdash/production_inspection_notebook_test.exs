defmodule Beamdash.ProductionInspectionNotebookTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Console, Notebook}

  test "a shared direct input remains live and retains its value until all displays are released" do
    {:ok, _} = Application.ensure_all_started(:kino)
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{widget: %{id: id}}} =
             Console.eval(
               node(),
               session,
               ~s|shared_input = Kino.Input.text("Name", default: "Ada")|
             )

    assert {:ok, :ok} = Console.set_input(node(), session, id, "Grace")

    assert {:ok, %{widget: %{id: ^id, value: "Grace"}}} =
             Console.eval(node(), session, "shared_input")

    assert {:ok, :ok} = Console.release_input(node(), session, id)
    assert {:ok, :ok} = Console.set_input(node(), session, id, "Lin")

    assert {:ok, %{result: ~s|"Lin"|}} =
             Console.eval(node(), session, "Kino.Input.read(shared_input)")

    assert {:ok, :ok} = Console.release_input(node(), session, id)
    assert {:ok, {:error, :not_found}} = Console.set_input(node(), session, id, "unused")
  end

  test "the threshold button visibly updates the frame with the selected value" do
    {:ok, notebook} =
      "livebooks/production-inspection-widgets.livemd"
      |> File.read!()
      |> Notebook.from_livemd()

    cells = Enum.filter(notebook.blocks, & &1.executable)

    input_cell =
      Enum.find(cells, &String.contains?(&1.source, "memory_threshold = Kino.Input.number"))

    frame_cell = Enum.find(cells, &String.contains?(&1.source, "status_frame = Kino.Frame.new()"))
    assert Notebook.execution_target(input_cell) == :local
    assert Notebook.execution_target(frame_cell) == :local

    {:ok, _} = Application.ensure_all_started(:kino)
    {:ok, session} = Console.start(node(), self(), :elixir)
    on_exit(fn -> Console.stop(session) end)

    assert {:ok, %{status: :ok}} =
             Console.eval(
               node(),
               session,
               "inspection = {:ok, %{node: :example, at: DateTime.utc_now(), memory: %{total: 10485760}, processes: 1, process_limit: 100, ports: 1, run_queue: 0}}"
             )

    assert {:ok, %{status: :ok, widget: %{id: input_id}}} =
             Console.eval(node(), session, input_cell.source)

    assert {:ok, %{status: :ok, widget: %{items: [%{widget: %{id: button_id}} | _]}}} =
             Console.eval(node(), session, frame_cell.source)

    assert {:ok, :ok} = Console.set_input(node(), session, input_id, "12")
    assert {:ok, :ok} = Console.set_input(node(), session, button_id, "click")
    assert_receive {:beamdash_kino_frame, ^session, _, 2, items}, 2_000
    assert inspect(items) =~ "Threshold: 12 MiB"
    assert inspect(items) =~ "Display updated:"
  end
end
