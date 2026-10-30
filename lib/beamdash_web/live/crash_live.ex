defmodule BeamdashWeb.CrashLive do
  @moduledoc "Crash reports from the target, newest first, with details on click."
  use Phoenix.LiveView

  alias Beamdash.{Crashes, Format, Target}

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()
    socket = assign(socket, status: status, node: node, reports: [], selected: nil)

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = Crashes.subscribe()
      {:ok, assign(socket, reports: Crashes.reports())}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, selected: if(socket.assigns.selected == id, do: nil, else: id))}
  end

  def handle_event("clear", _params, socket) do
    :ok = Crashes.clear()
    {:noreply, assign(socket, reports: [], selected: nil)}
  end

  @impl true
  def handle_info({:beamdash_crash, :cleared}, socket),
    do: {:noreply, assign(socket, reports: [], selected: nil)}

  def handle_info({:beamdash_crash, crash}, socket),
    do: {:noreply, update(socket, :reports, &[crash | &1])}

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do: {:noreply, assign(socket, status: :connected, node: node)}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected)}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap">
      <BeamdashWeb.Layouts.header
        active={:crashes}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected and @reports == []} class="help">
        Not connected: enter a node above and click Connect.
      </p>

      <div class="active-traces">
        <strong>{length(@reports)} crash reports</strong>
        <span class="muted small">
          from processes started with proc_lib (gen_servers, supervisor children, Tasks…) exiting abnormally since you connected
        </span>
        <button :if={@reports != []} class="secondary" phx-click="clear">Clear</button>
      </div>

      <table :if={@reports != []} class="log crash-table">
        <thead>
          <tr>
            <th>Time (UTC)</th>
            <th>Process</th>
            <th>Started as</th>
            <th>Reason</th>
          </tr>
        </thead>
        <tbody>
          <%= for c <- @reports do %>
            <tr
              class={["clickable exception", c.id == @selected && "selected"]}
              phx-click="select"
              phx-value-id={c.id}
            >
              <td class="mono">{c.at |> DateTime.to_time() |> Time.truncate(:millisecond)}</td>
              <td class="mono">
                {if c.registered_name,
                  do: Format.name(c.registered_name, @syntax),
                  else: pid(c.pid, @syntax)}
              </td>
              <td class="mono">{Format.mfa(c.initial_call, @syntax)}</td>
              <td class="mono">{c.class}: {Format.term(c.reason, @syntax)}</td>
            </tr>
            <tr :if={c.id == @selected} class="expanded">
              <td colspan="4">
                <div class="detail">
                  <h4>{c.class}</h4>
                  <pre><%= Format.pretty(c.reason, @syntax) %></pre>
                  <h4 :if={c.stack != []}>Stack</h4>
                  <pre :if={c.stack != []}><%= stack(c.stack, @syntax) %></pre>
                  <h4>Process</h4>
                  <table class="props">
                    <tr :for={{k, v} <- c.props}>
                      <th>{k}</th>
                      <td class="mono"><pre><%= Format.pretty(v, @syntax) %></pre></td>
                    </tr>
                  </table>
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </main>
    """
  end

  defp pid(pid, syntax) when is_pid(pid), do: Format.pid(pid, syntax)
  defp pid(other, syntax), do: Format.term(other, syntax)

  defp stack(stack, syntax) do
    Enum.map_join(stack, "\n", fn
      {m, f, a, loc} ->
        where =
          case {loc[:file], loc[:line]} do
            {nil, _} -> ""
            {file, nil} -> "  (#{file})"
            {file, line} -> "  (#{file}:#{line})"
          end

        Format.mfa({m, f, a}, syntax) <> where

      other ->
        Format.term(other, syntax)
    end)
  end
end
