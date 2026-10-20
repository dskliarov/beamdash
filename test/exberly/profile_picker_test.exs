defmodule Exberly.ProfilePickerTest do
  use ExUnit.Case, async: true
  alias ExberlyWeb.ProfileLive

  @modules [
    {:shop, [price: 2, start: 0, module_info: 0], [unit: 1, "-loop/0-fun-0-": 1]},
    {:door, [open: 0], []}
  ]

  defp socket do
    {:ok, socket} = ProfileLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    Phoenix.Component.assign(socket,
      syntax: :erlang,
      status: :connected,
      node: :demo@host,
      available: true,
      modules: @modules
    )
  end

  defp html(socket),
    do: ProfileLive.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()

  defp event(socket, name, params) do
    {:noreply, socket} = ProfileLive.handle_event(name, params, socket)
    socket
  end

  test "a whole module replaces its single functions, and covers new ones" do
    picks = ProfileLive.toggle_pick([], {:shop, :price, 2})
    picks = ProfileLive.toggle_pick(picks, {:door, :open, 0})
    assert picks == [{:shop, :price, 2}, {:door, :open, 0}]
    picks = ProfileLive.toggle_pick(picks, {:shop, :_, :_})
    assert picks == [{:door, :open, 0}, {:shop, :_, :_}]
    assert ProfileLive.toggle_pick(picks, {:shop, :unit, 1}) == picks
    assert ProfileLive.toggle_pick(picks, {:shop, :_, :_}) == [{:door, :open, 0}]
  end

  test "choosing a module lists its functions; clicking them picks them" do
    s = socket()
    assert html(s) =~ "Pick a module or functions below"
    s = event(s, "pick_module", %{"mod" => "shop"})
    h = html(s)
    # exported first, then local; funs and module_info hidden
    assert h =~ "Whole module (3 functions)"
    assert h =~ "price"
    assert h =~ "unit"
    refute h =~ "module_info"
    refute h =~ "-loop"

    s = event(s, "pick", %{"mod" => "shop", "fun" => "unit", "arity" => "1"})
    s = event(s, "pick", %{"mod" => "shop", "fun" => "price", "arity" => "2"})
    assert s.assigns.picked == [{:shop, :unit, 1}, {:shop, :price, 2}]
    assert html(s) =~ "shop:unit/1"

    s = event(s, "pick_search", %{"fq" => "pri"})
    s = event(s, "pick_ff", %{"f" => "picked"})
    h = html(s)
    assert h =~ "price"

    s = event(s, "pick", %{"mod" => "shop", "fun" => "_", "arity" => "_"})
    assert s.assigns.picked == [{:shop, :_, :_}]
    assert html(s) =~ "shop (whole module)"
  end

  test "starting without picks or patterns explains what is needed" do
    s = socket()

    s =
      event(s, "start", %{
        "profile" => %{
          "type" => "call_time",
          "patterns" => "",
          "procs" => "all",
          "seconds" => "5"
        }
      })

    assert s.assigns.form_error =~ "at least one module or function"
  end

  test "module filter narrows the list" do
    s = socket() |> event("pick_search", %{"pick_q" => "do"})
    h = html(s)
    assert h =~ "1 of 2 loaded modules"
    assert h =~ ~s(phx-value-mod="door")
    refute h =~ ~s(phx-value-mod="shop")
  end
end
