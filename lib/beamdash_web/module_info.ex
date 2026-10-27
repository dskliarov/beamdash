defmodule BeamdashWeb.ModuleInfo do
  @moduledoc """
  The module that runs a process (`Beamdash.Apps.module_summary/2`), as the
  Apps tab and the Processes tab's details panel show it: what it is, where
  it was loaded from, and links to trace or profile it, or to read its
  source (only when it has one: `has_source`). The page handles the
  Source button's `open_source` event with `BeamdashWeb.SourceTabs`.
  """
  use Phoenix.Component

  alias Beamdash.Format

  attr :module, :map, required: true, doc: "`Beamdash.Apps.module_summary/2`"
  attr :syntax, :atom, default: :erlang

  def section(assigns) do
    ~H"""
    <div class="module-info">
      <div class="module-info-head">
        <strong class="mono">{Format.name(@module.module, @syntax)}</strong>
        <span class="muted small">the module that runs it</span>
        <.link
          navigate={"/trace?mod=" <> URI.encode_www_form(Atom.to_string(@module.module))}
          class="btn-link small-btn"
          title="Pick functions of this module to trace, on the Trace tab"
        >
          Trace ↗
        </.link>
        <.link
          navigate={"/profile?mod=" <> URI.encode_www_form(Atom.to_string(@module.module))}
          class="btn-link small-btn"
          title="Pick functions of this module to profile, on the Profile tab"
        >
          Profile ↗
        </.link>
        <button
          :if={@module[:has_source]}
          type="button"
          class="secondary small-btn"
          phx-click="open_source"
          phx-value-mod={@module.module}
          title="Open the module's source in a tab"
        >
          Source
        </button>
      </div>
      <dl class="apps-details">
        <dt :if={@module.behaviours != []}>Behaviours</dt>
        <dd :if={@module.behaviours != []} class="mono">
          {Enum.map_join(@module.behaviours, ", ", &Format.name(&1, @syntax))}
        </dd>
        <dt :if={@module.application}>Application</dt>
        <dd :if={@module.application} class="mono">{@module.application}</dd>
        <dt>Exports</dt>
        <dd>{@module.exports} functions</dd>
        <dt :if={@module.vsn != []}>Version</dt>
        <dd :if={@module.vsn != []} class="mono">{Format.term(@module.vsn, @syntax)}</dd>
        <dt :if={@module.source}>Source</dt>
        <dd :if={@module.source} class="mono">{@module.source}</dd>
        <dt>Loaded from</dt>
        <dd class="mono">{@module.file}</dd>
      </dl>
    </div>
    """
  end
end
