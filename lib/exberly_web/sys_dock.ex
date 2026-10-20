defmodule ExberlyWeb.SysDock do
  @moduledoc """
  The dock along the bottom of the window: panels stacked one above the
  other, of three kinds: sys:trace events (`ExberlyWeb.SysPanel`), the
  state of a gen_server or gen_statem (`ExberlyWeb.StatePanel`) and a
  supervision tree (`ExberlyWeb.TreePanel`). The active panel is
  maximized and fills the dock; the others are minimized to their header.
  The dock is resized by dragging its top edge.
  """
  use Phoenix.Component

  alias ExberlyWeb.{StatePanel, SysPanel, TreePanel}

  attr :panels, :list,
    required: true,
    doc: "[%{kind: :trace | :state | :tree, pid, label, proc_kind}] in display order"

  attr :active, :any, required: true, doc: "{kind, pid} of the maximized panel"
  attr :collapsed, :boolean, required: true
  attr :syntax, :atom, required: true

  def dock(assigns) do
    ~H"""
    <section
      id="sys-dock"
      class={["sys-dock", @collapsed && "collapsed"]}
      aria-label="Process panels"
      phx-hook="DockSpacer"
    >
      <div
        :if={!@collapsed}
        id="dock-resizer"
        class="resizer resizer-y dock-resizer"
        phx-hook="Resizer"
        phx-update="ignore"
        data-var="--dock-h"
        data-axis="y"
        data-grow="up"
        data-target="#sys-dock"
        data-min="120"
        data-max="4000"
        role="separator"
        aria-orientation="horizontal"
        aria-label="Resize the panels"
        tabindex="0"
        title="Drag to resize · double-click to reset"
      >
      </div>

      <header class="dock-head">
        <h4>Panels</h4>
        <span class="muted small">{counts_text(@panels)}</span>
        <span class="dock-actions">
          <button
            class="secondary small-btn"
            phx-click="dock_collapse"
            title={if @collapsed, do: "Show the panels", else: "Hide the panels"}
            aria-expanded={to_string(!@collapsed)}
          >
            {if @collapsed, do: "▴", else: "▾"}
          </button>
        </span>
      </header>

      <%!-- hidden rather than removed, so the panels keep their events --%>
      <div class="dock-body dock-stack" hidden={@collapsed}>
        <%= for p <- @panels do %>
          <.live_component
            :if={p.kind == :trace}
            module={SysPanel}
            id={"sys-panel-" <> key(p.pid)}
            key={key(p.pid)}
            active={{p.kind, p.pid} == @active}
            pid={p.pid}
            label={p.label}
            syntax={@syntax}
          />
          <.live_component
            :if={p.kind == :state}
            module={StatePanel}
            id={"state-panel-" <> key(p.pid)}
            key={key(p.pid)}
            active={{p.kind, p.pid} == @active}
            pid={p.pid}
            label={p.label}
            proc_kind={p.proc_kind}
            syntax={@syntax}
          />
          <.live_component
            :if={p.kind == :tree}
            module={TreePanel}
            id={"tree-panel-" <> key(p.pid)}
            key={key(p.pid)}
            active={{p.kind, p.pid} == @active}
            pid={p.pid}
            label={p.label}
            syntax={@syntax}
          />
        <% end %>
      </div>
    </section>
    """
  end

  defp counts_text(panels) do
    [trace: "sys:trace", state: "state", tree: "supervisor tree"]
    |> Enum.map(fn {kind, label} -> {label, Enum.count(panels, &(&1.kind == kind))} end)
    |> Enum.reject(fn {_label, n} -> n == 0 end)
    |> Enum.map_join(" · ", fn {label, n} -> "#{n} #{label}" end)
  end

  @doc "DOM-safe key for a process: its pid's numbers."
  def key(pid),
    do:
      pid
      |> :erlang.pid_to_list()
      |> List.to_string()
      |> String.replace(~r/\D+/, "-")
      |> String.trim("-")
end
