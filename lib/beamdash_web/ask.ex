defmodule BeamdashWeb.Ask do
  @moduledoc """
  `on_mount` hook behind the "Ask beamdash" box in the header of every
  tab (`BeamdashWeb.Layouts.header/1`): the typed question goes to
  `Beamdash.AskAdvisor` in the background; a clear answer navigates to
  that view, otherwise the likely views are listed under the box.
  `@ask` is `%{query, busy, options, error}`.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_navigate: 2]

  alias Beamdash.{AskAdvisor, Target, Tracer}

  @empty %{query: "", busy: nil, options: [], error: nil}

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:ask, @empty)
      |> attach_hook(:ask_event, :handle_event, &handle_event/3)
      |> attach_hook(:ask_info, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  @doc false
  def handle_event("ask", %{"ask_q" => q}, socket) do
    q = String.trim(q)

    if q == "" or socket.assigns.ask.busy do
      {:halt, socket}
    else
      ref = make_ref()
      parent = self()
      module = loaded_module(q)

      spawn(fn ->
        result =
          try do
            AskAdvisor.ask(q, module)
          catch
            _, _ -> {:error, "#{Beamdash.Jev.name()} could not be reached. Try again."}
          end

        send(parent, {:beamdash_ask, ref, result})
      end)

      {:halt, assign(socket, :ask, %{@empty | query: q, busy: ref})}
    end
  end

  def handle_event("ask_close", _params, socket),
    do: {:halt, assign(socket, :ask, %{@empty | query: socket.assigns.ask.query})}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  @doc false
  def handle_info({:beamdash_ask, ref, result}, %{assigns: %{ask: %{busy: ref}}} = socket) do
    ask = %{socket.assigns.ask | busy: nil}

    case result do
      {:ok, %{go: path}} when is_binary(path) ->
        {:halt, socket |> assign(:ask, %{ask | query: ""}) |> push_navigate(to: path)}

      {:ok, %{options: []}} ->
        {:halt,
         assign(socket, :ask, %{
           ask
           | error: "No view of beamdash answers that. Try other words."
         })}

      {:ok, %{options: options}} ->
        {:halt, assign(socket, :ask, %{ask | options: options})}

      {:error, message} ->
        {:halt, assign(socket, :ask, %{ask | error: message})}
    end
  end

  # a late answer to a question asked before
  def handle_info({:beamdash_ask, _ref, _result}, socket), do: {:halt, socket}
  def handle_info(_message, socket), do: {:cont, socket}

  defp loaded_module(q) do
    with %{status: :connected} <- Target.status(),
         {:ok, mods} <- Tracer.module_functions() do
      AskAdvisor.module_in(q, Enum.map(mods, &elem(&1, 0)))
    else
      _ -> nil
    end
  end
end
