defmodule BeamdashWeb.Syntax do
  @moduledoc """
  `on_mount` hook shared by every page: assigns `@syntax` (`:erlang` or
  `:elixir`), handles the nav's `set_syntax` button and follows changes
  made in other tabs.

  A page whose content is not re-rendered by an assign change (LiveView
  streams) can define `syntax_changed/1` to rebuild it.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Beamdash.Settings

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Beamdash.PubSub, "settings")

    socket =
      socket
      |> assign(:syntax, Settings.syntax())
      |> assign(:jev_enabled, Settings.jev_enabled?())
      |> attach_hook(:syntax_event, :handle_event, &handle_event/3)
      |> attach_hook(:syntax_info, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_event("set_syntax", %{"syntax" => value}, socket) when value in ~w(erlang elixir) do
    syntax = String.to_existing_atom(value)
    :ok = Settings.put_syntax(syntax)
    {:halt, change(socket, syntax)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:beamdash_syntax, syntax}, %{assigns: %{syntax: syntax}} = socket),
    do: {:halt, socket}

  defp handle_info({:beamdash_syntax, syntax}, socket), do: {:halt, change(socket, syntax)}

  defp handle_info({:beamdash_jev, enabled}, socket) do
    socket = assign(socket, :jev_enabled, enabled)

    socket =
      if function_exported?(socket.view, :jev_changed, 1),
        do: socket.view.jev_changed(socket),
        else: socket

    {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp change(socket, syntax) do
    socket = assign(socket, :syntax, syntax)

    if function_exported?(socket.view, :syntax_changed, 1),
      do: socket.view.syntax_changed(socket),
      else: socket
  end
end
