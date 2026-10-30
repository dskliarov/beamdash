defmodule BeamdashWeb.LoadLive do
  @moduledoc """
  Observer's Load Charts tab: scheduler utilization (one line per
  scheduler, dirty CPU schedulers dotted), memory usage and IO usage over
  the last 60 s, sampled twice a second while the tab is open.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Load, Target}

  # Lines for schedulers: distinct in light and dark themes
  @palette ~w(#2a78d6 #eb6834 #1baf7a #eda100 #e87ba4 #008300 #7c3aed #0f766e
              #b45309 #db2777 #4f46e5 #65a30d #0891b2 #c2410c #9333ea #ca8a04)

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket, status: status, node: node, load: Load.new(), sampler: nil, error: nil)

    if connected?(socket) do
      :ok = Target.subscribe()
      {:ok, start_sampler(socket)}
    else
      {:ok, socket}
    end
  end

  defp start_sampler(%{assigns: %{status: :connected, node: node}} = socket) do
    case Load.start(node) do
      {:ok, pid} -> assign(socket, sampler: pid, load: Load.new(), error: nil)
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  defp start_sampler(socket), do: socket

  @impl true
  def handle_info({:beamdash_load, pid, sample}, %{assigns: %{sampler: pid}} = socket),
    do: {:noreply, update(socket, :load, &Load.add(&1, sample))}

  # from a sampler of an earlier connection
  def handle_info({:beamdash_load, _pid, _sample}, socket), do: {:noreply, socket}

  def handle_info({:beamdash_target, {:connected, node}}, socket) do
    Load.stop(socket.assigns.sampler)
    {:noreply, socket |> assign(status: :connected, node: node) |> start_sampler()}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, sampler: nil, load: Load.new())}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  @impl true
  def render(assigns) do
    assigns = assign(assigns, charts: charts(assigns.load))

    ~H"""
    <main class="wrap load-page">
      <BeamdashWeb.Layouts.header
        active={:load}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@error} class="error">{@error}</p>

      <%= if @status == :connected do %>
        <p class="muted small load-note">
          As Observer's Load Charts: sampled twice a second, last 60 s. While this tab is open the node keeps
          <code>scheduler_wall_time</code>
          on (it turns off when you leave).
        </p>
        <p :if={@charts == nil} class="muted">Collecting the first samples…</p>
        <div :if={@charts} class="load-grid">
          <.chart id="chart-sched" class="load-wide" {@charts.util} />
          <.chart id="chart-mem" {@charts.memory} />
          <.chart id="chart-io" {@charts.io} />
        </div>
      <% end %>
    </main>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :title, :string, required: true
  attr :series, :list, required: true, doc: "[%{label, color, dashed, points, last}]"
  attr :max, :any, required: true
  attr :format, :any, required: true
  attr :note, :string, default: nil
  attr :grouped, :boolean, default: false, doc: "legend in scheduler groups, as a grid"

  # A line chart: x is the last 60 s, y from 0 to max. Lines are drawn in
  # a stretched SVG (non-scaling strokes); labels are HTML so they do not
  # stretch with it.
  defp chart(assigns) do
    ~H"""
    <section class={["load-card", @class]} id={@id} aria-label={@title}>
      <h3>{@title}</h3>
      <div class="load-plot">
        <div class="load-y" aria-hidden="true">
          <span>{@format.(@max)}</span>
          <span>{@format.(@max / 2)}</span>
          <span>0</span>
        </div>
        <svg
          viewBox="0 -2 600 204"
          preserveAspectRatio="none"
          role="img"
          aria-label={"#{@title}, last 60 s"}
        >
          <line :for={y <- [0, 100, 200]} x1="0" x2="600" y1={y} y2={y} class="load-grid-line" />
          <polyline
            :for={{s, i} <- Enum.with_index(@series)}
            points={s.points}
            fill="none"
            stroke={s.color}
            stroke-width="1.6"
            stroke-dasharray={s.dashed && "3 3"}
            vector-effect="non-scaling-stroke"
            data-s={i}
          />
        </svg>
        <div class="load-x muted small" aria-hidden="true">
          <span>−60 s</span><span>−30 s</span><span>now</span>
        </div>
      </div>
      <%!-- hovering or focusing a legend item highlights its line --%>
      <style>
        <%= Phoenix.HTML.raw(highlight_css(@id, length(@series))) %>
      </style>
      <%= if @grouped do %>
        <div :for={{group, items} <- legend_groups(@series)} class="load-legend-group">
          <h4>
            {group_title(group)}
            <span class="muted">· {length(items)} · now avg {avg_pct(items)}%</span>
          </h4>
          <ul class="load-legend grid">
            <.legend_item :for={{s, i} <- items} s={s} i={i} />
          </ul>
        </div>
      <% else %>
        <ul class="load-legend">
          <.legend_item :for={{s, i} <- Enum.with_index(@series)} s={s} i={i} />
        </ul>
      <% end %>
      <p :if={@note} class="muted small">{@note}</p>
    </section>
    """
  end

  attr :s, :map, required: true
  attr :i, :integer, required: true

  defp legend_item(assigns) do
    ~H"""
    <li data-s={@i} tabindex="0" title={@s[:title] || @s.label} class="load-item">
      <span class={["load-swatch", @s.dashed && "dashed"]} style={"--c: #{@s.color}"}></span>
      <span class="load-name">{@s.label}</span>
      <span class="load-value">{@s.last}</span>
      <span :if={@s[:pct]} class="load-meter" aria-hidden="true">
        <span style={"width: #{min(round(@s.pct), 100)}%; background: #{@s.color}"}></span>
      </span>
    </li>
    """
  end

  # Fade every other line while a legend item is hovered or focused.
  defp highlight_css(id, n) do
    Enum.map_join(0..(n - 1)//1, "\n", fn i ->
      on = "##{id}:has(.load-item[data-s=\"#{i}\"]:is(:hover, :focus-visible))"

      "#{on} polyline:not([data-s=\"#{i}\"]) { opacity: .12; } " <>
        "#{on} polyline[data-s=\"#{i}\"] { stroke-width: 2.8; } " <>
        "#{on} .load-item:not([data-s=\"#{i}\"]) { opacity: .45; }"
    end)
  end

  # [{group, [{series, index}]}], index counting across groups
  defp legend_groups(series) do
    series
    |> Enum.with_index()
    |> Enum.chunk_by(fn {s, _} -> s.group end)
    |> Enum.map(fn [{s, _} | _] = items -> {s.group, items} end)
  end

  defp group_title(:normal), do: "Schedulers"
  defp group_title(:dirty), do: "Dirty CPU schedulers (dotted)"

  defp avg_pct(items),
    do: round(Enum.sum(Enum.map(items, fn {s, _} -> s.pct end)) / max(length(items), 1))

  @doc false
  # nil until two samples have arrived
  def charts(%{points: []}), do: nil

  def charts(%{points: points, schedulers: schedulers}) do
    now = List.last(points).at_ms
    x = fn at -> Float.round(600 - (now - at) / Load.window_ms() * 600, 1) end
    y = fn v, max -> Float.round(200 - min(v / max, 1.0) * 200, 1) end

    line = fn values, max ->
      Enum.map_join(values, " ", fn {at, v} -> "#{x.(at)},#{y.(v, max)}" end)
    end

    util_points = Enum.filter(points, & &1.util)
    lanes = util_points |> List.last() |> then(&((&1 && length(&1.util)) || 0))

    util_series =
      for i <- 0..(lanes - 1)//1 do
        values = for p <- util_points, do: {p.at_ms, Enum.at(p.util, i)}
        normal? = i < schedulers

        now_pct = elem(List.last(values), 1)

        %{
          label: if(normal?, do: "#{i + 1}", else: "#{i + 1 - schedulers}"),
          title:
            if(normal?,
              do: "Scheduler #{i + 1}",
              else: "Dirty CPU scheduler #{i + 1 - schedulers}"
            ),
          group: if(normal?, do: :normal, else: :dirty),
          color: Enum.at(@palette, rem(i, length(@palette))),
          dashed: not normal?,
          points: line.(values, 100),
          last: "#{round(now_pct)}%",
          pct: now_pct
        }
      end

    mem_max = points |> Enum.map(&(&1.memory[:total] || 0)) |> Enum.max() |> nice_bytes()

    mem_series =
      for {kind, i} <- Enum.with_index(Load.memory_kinds()) do
        values = for p <- points, do: {p.at_ms, p.memory[kind] || 0}

        %{
          label: Atom.to_string(kind),
          color: "var(--mem-#{i + 1})",
          dashed: false,
          points: line.(values, mem_max),
          last: Format.bytes(elem(List.last(values), 1))
        }
      end

    io_max =
      points |> Enum.flat_map(&Tuple.to_list(&1.io)) |> Enum.max() |> max(1024) |> nice_bytes()

    io_series =
      for {label, i} <- [{"input", 0}, {"output", 1}] do
        values = for p <- points, do: {p.at_ms, elem(p.io, i)}

        %{
          label: label,
          color: "var(--mem-#{i + 1})",
          dashed: false,
          points: line.(values, io_max),
          last: rate(elem(List.last(values), 1))
        }
      end

    %{
      util: %{
        title: "Scheduler Utilization (%)",
        series: util_series,
        max: 100,
        format: &"#{round(&1)}",
        grouped: true,
        note: if(util_points == [], do: "scheduler_wall_time is not available on this node.")
      },
      memory: %{title: "Memory Usage", series: mem_series, max: mem_max, format: &bytes/1},
      io: %{title: "IO Usage", series: io_series, max: io_max, format: &rate/1}
    }
  end

  @doc false
  # An axis top for bytes: 1, 2 or 5 × 10^n of the unit the value is shown in
  # (B, KB, MB, GB), so the label is round: 5.0 MB, not 4.8 MB.
  def nice_bytes(n) when n <= 1024, do: 1024

  def nice_bytes(n) do
    unit = Enum.find([1_073_741_824, 1_048_576, 1024], &(n >= &1))
    round(nice(n / unit) * unit)
  end

  @doc false
  # 1, 2 or 5 × 10^n at or above n
  def nice(n) when n <= 0, do: 1

  def nice(n) do
    exp = :math.pow(10, floor(:math.log10(n)))
    Enum.find([1, 2, 5, 10], &(&1 * exp >= n)) * exp
  end

  defp bytes(n), do: Format.bytes(round(n))
  defp rate(n), do: "#{Format.bytes(round(n))}/s"
end
