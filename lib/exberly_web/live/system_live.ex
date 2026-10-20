defmodule ExberlyWeb.SystemLive do
  @moduledoc """
  The node at a glance, as Observer's System tab shows it: system and
  architecture, memory usage, CPUs and threads, statistics, and system
  counts against their limits. Refreshed every 10 s (Observer's default)
  or on demand.
  """
  use Phoenix.LiveView

  alias Exberly.{Format, Target}

  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()
    socket = assign(socket, status: status, node: node, info: nil, at: nil, error: nil)

    if connected?(socket) do
      :ok = Target.subscribe()
      Process.send_after(self(), :refresh, @refresh_ms)
      {:ok, load(socket)}
    else
      {:ok, socket}
    end
  end

  defp load(%{assigns: %{status: :connected}} = socket) do
    case Target.system_info() do
      {:ok, info} -> assign(socket, info: info, at: DateTime.utc_now(), error: nil)
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  defp load(socket), do: socket

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info({:exberly_target, {:connected, node}}, socket),
    do: {:noreply, socket |> assign(status: :connected, node: node) |> load()}

  def handle_info({:exberly_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, info: nil, at: nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap system-page">
      <ExberlyWeb.Layouts.header
        active={:system}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={ExberlyWeb.JevSection.show?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@error} class="error">{@error}</p>

      <%= if @status == :connected and @info do %>
        <div class="sys-head">
          <span class="muted small">
            As Observer's System tab · updated {Calendar.strftime(@at, "%H:%M:%S")} UTC, every 10 s
          </span>
          <button class="secondary small-btn" phx-click="refresh">Refresh</button>
        </div>

        <div class="sys-grid">
          <.card title="System and Architecture" rows={system_rows(@info)} />
          <.card title="Memory Usage" rows={memory_rows(@info)} right />
          <.card title="CPUs and Threads" rows={cpu_rows(@info)} />
          <.card title="Statistics" rows={stats_rows(@info)} right />
          <section class="sys-card sys-wide" aria-labelledby="sys-limits">
            <h3 id="sys-limits">System statistics / limit</h3>
            <table class="sys-table">
              <tr :for={{label, count, limit} <- limit_rows(@info)}>
                <th>{label}</th>
                <td class="num">{limit_text(count, limit)}</td>
                <td class="sys-bar-cell">
                  <span
                    :if={pct = used_pct(count, limit)}
                    class={["sys-bar", pct >= 80 && "high"]}
                    role="meter"
                    aria-valuemin="0"
                    aria-valuemax="100"
                    aria-valuenow={pct}
                    aria-label={"#{label}: #{pct}% of the limit used"}
                  >
                    <span style={"width: #{max(pct, 1)}%"}></span>
                  </span>
                </td>
              </tr>
              <tr>
                <th>Distribution buffer busy limit</th>
                <td class="num">{maybe_bytes(@info.dist_buf_busy_limit)}</td>
                <td></td>
              </tr>
            </table>
          </section>
        </div>
      <% end %>
    </main>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :right, :boolean, default: false

  defp card(assigns) do
    ~H"""
    <section class="sys-card" aria-label={@title}>
      <h3>{@title}</h3>
      <table class="sys-table">
        <tr :for={{label, value} <- @rows}>
          <th>{label}</th>
          <td class={@right && "num"}>{value}</td>
        </tr>
      </table>
    </section>
    """
  end

  # Observer's labels and order (observer_sys_wx:info_fields/0)

  @doc false
  def system_rows(i) do
    [
      {"System Version", text(i.otp_release)},
      {"ERTS Version", text(i.version)},
      {"Compiled for", text(i.system_architecture)},
      {"Emulator Wordsize", wordsize(i.wordsize_external)},
      {"Process Wordsize", wordsize(i.wordsize_internal)},
      {"SMP Support", text(i.smp_support)},
      {"Thread Support", text(i.threads)},
      {"Async thread pool size", text(i.thread_pool_size)}
    ]
  end

  @doc false
  def memory_rows(i) do
    m = i.memory

    [
      {"Total", maybe_bytes(m[:total])},
      {"Processes", maybe_bytes(m[:processes])},
      {"Atoms", maybe_bytes(m[:atom])},
      {"Binaries", maybe_bytes(m[:binary])},
      {"Code", maybe_bytes(m[:code])},
      {"ETS", maybe_bytes(m[:ets])}
    ]
  end

  @doc false
  def cpu_rows(i) do
    [
      {"Logical CPUs", text(i.logical_processors)},
      {"Online Logical CPUs", text(i.logical_processors_online)},
      {"Available Logical CPUs", text(i.logical_processors_available)},
      {"Schedulers", text(i.schedulers)},
      {"Online schedulers", text(i.schedulers_online)},
      {"Available schedulers", text(i.schedulers_available)}
    ]
  end

  @doc false
  def stats_rows(i) do
    [
      {"Up time", uptime(i.uptime_ms)},
      {"Run Queue", text(i.run_queue)},
      {"IO Input", maybe_bytes(i.io_input)},
      {"IO Output", maybe_bytes(i.io_output)}
    ]
  end

  @doc false
  def limit_rows(i) do
    [
      {"Atoms", i.atom_count, i.atom_limit},
      {"Processes", i.process_count, i.process_limit},
      {"Ports", i.port_count, i.port_limit},
      {"ETS", i.ets_count, i.ets_limit}
    ]
  end

  @doc false
  # "count / limit (n % used)", as Observer writes it
  def limit_text(count, limit) do
    used = if pct = used_pct(count, limit), do: " (#{pct} % used)", else: ""
    "#{text(count)} / #{text(limit)}#{used}"
  end

  defp used_pct(count, limit)
       when is_integer(count) and is_integer(limit) and limit > 0,
       do: trunc(count / limit * 100)

  defp used_pct(_, _), do: nil

  defp text(nil), do: "Not available"
  defp text(:undefined), do: "Not available"
  defp text(n) when is_integer(n), do: Format.number(n)
  defp text(v), do: to_string(v)

  defp maybe_bytes(n) when is_integer(n), do: Format.bytes(n)
  defp maybe_bytes(other), do: text(other)

  defp wordsize(n) when is_integer(n), do: "#{n} bytes (#{n * 8}-bit)"
  defp wordsize(other), do: text(other)

  @doc false
  # Observer: "1 Days 2:03:04"
  def uptime(ms) when is_integer(ms) do
    s = div(ms, 1000)
    {days, s} = {div(s, 86_400), rem(s, 86_400)}
    {h, s} = {div(s, 3600), rem(s, 3600)}
    {m, s} = {div(s, 60), rem(s, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "#{days} #{if days == 1, do: "day", else: "days"} #{h}:#{pad.(m)}:#{pad.(s)}"
  end

  def uptime(other), do: text(other)
end
