defmodule BeamdashWeb.SourceTabs do
  @moduledoc """
  Module source tabs on the Trace and Profile tabs. The **Source** button
  next to the selected module opens its source (`Beamdash.ModuleSource`)
  in a tab beside the page's own one; each source tab can be closed.

  The page keeps `@sources` (the open ones, in order) and `@source_tab`
  (the module shown, or `nil` for the page itself), set by `init/1`, and
  passes the events named in `events/0` to `event/3`. While a source is
  shown, the page's own content stays rendered but hidden (`hidden`), so a
  stream such as the Trace log keeps its rows.
  """
  use Phoenix.Component

  alias Beamdash.{Format, ModuleSource}

  @doc "The events `event/3` handles."
  def events, do: ~w(open_source source_tab close_source)

  @doc "No source open, and nothing known yet of which modules have one."
  def init(socket), do: assign(socket, sources: [], source_tab: nil, source_known: %{})

  @doc """
  Asks the node, once per module, whether `mod` has a source to show
  (`Beamdash.ModuleSource.available?/2`), for `available?/2`. A page calls
  it when the module it shows a Source button for changes; `init/1` (on a
  new node) forgets the answers.
  """
  def check(socket, nil), do: socket

  def check(%{assigns: %{source_known: known}} = socket, mod) when is_map_key(known, mod),
    do: socket

  def check(socket, mod) do
    available = Beamdash.ModuleSource.available?(socket.assigns[:node], mod)
    assign(socket, source_known: Map.put(socket.assigns.source_known, mod, available))
  end

  @doc "Whether `check/2` found a source for `mod`: the Source button shows only then."
  def available?(known, mod), do: Map.get(known, mod, false)

  @doc """
  Handles one of `events/0`. A module name from the browser is only taken
  when it is one of `modules` (the page's `@modules` by default,
  `[{mod, exported, local}]`, or plain module atoms), so no atom is made
  from it.
  """
  def event(name, params, socket, modules \\ nil)

  def event("open_source", %{"mod" => text}, socket, modules) do
    case find_module(modules || socket.assigns.modules, text) do
      nil ->
        socket

      mod ->
        sources = socket.assigns.sources

        sources =
          if Enum.any?(sources, &(&1.mod == mod)),
            do: sources,
            else: sources ++ [load(socket.assigns.node, mod)]

        assign(socket, sources: sources, source_tab: mod)
    end
  end

  def event("source_tab", %{"tab" => "main"}, socket, _modules),
    do: assign(socket, source_tab: nil)

  def event("source_tab", %{"tab" => text}, socket, _modules) do
    case Enum.find(socket.assigns.sources, &(Atom.to_string(&1.mod) == text)) do
      nil -> socket
      %{mod: mod} -> assign(socket, source_tab: mod)
    end
  end

  # closing the tab shown shows its neighbour, else the page
  def event("close_source", %{"mod" => text}, socket, _modules) do
    %{sources: sources, source_tab: current} = socket.assigns

    case Enum.find_index(sources, &(Atom.to_string(&1.mod) == text)) do
      nil ->
        socket

      i ->
        closed = Enum.at(sources, i).mod
        left = List.delete_at(sources, i)

        current =
          if current == closed,
            do: left |> Enum.at(min(i, length(left) - 1)) |> then(&(&1 && &1.mod)),
            else: current

        assign(socket, sources: left, source_tab: current)
    end
  end

  defp find_module(modules, text) do
    Enum.find_value(modules, fn
      {m, _, _} -> Atom.to_string(m) == text && m
      m when is_atom(m) -> Atom.to_string(m) == text && m
    end)
  end

  defp load(node, mod) do
    case ModuleSource.get(node, mod) do
      {:ok, %{kind: :none} = source} ->
        %{mod: mod, source: source, lines: []}

      {:ok, source} ->
        # as a <pre> shows it: no empty line after the last newline
        lines = source.text |> String.trim_trailing("\n") |> String.split(~r/\r?\n/)
        %{mod: mod, source: source, lines: lines}

      {:error, reason} ->
        %{mod: mod, source: %{kind: :error, path: nil, reason: Format.error(reason)}, lines: []}
    end
  end

  attr :sources, :list, required: true
  attr :current, :atom, default: nil
  attr :main_label, :string, required: true
  attr :syntax, :atom, default: :erlang

  @doc "The tab bar: the page's own tab, then one per open source. Nothing while none is open."
  def tabs(assigns) do
    ~H"""
    <nav :if={@sources != []} class="seg src-tabs" role="tablist" aria-label="Page and sources">
      <button
        type="button"
        role="tab"
        aria-selected={to_string(@current == nil)}
        class={["seg-btn", @current == nil && "active"]}
        phx-click="source_tab"
        phx-value-tab="main"
      >
        {@main_label}
      </button>
      <.source_buttons sources={@sources} current={@current} syntax={@syntax} />
    </nav>
    """
  end

  attr :sources, :list, required: true
  attr :current, :atom, default: nil
  attr :syntax, :atom, default: :erlang

  @doc """
  One tab per open source, with its close button: the tail of `tabs/1`, or
  of a page's own tab row (the Apps tab's).
  """
  def source_buttons(assigns) do
    ~H"""
    <span :for={s <- @sources} class={["src-tab", @current == s.mod && "active"]}>
      <button
        type="button"
        role="tab"
        aria-selected={to_string(@current == s.mod)}
        class={["seg-btn", @current == s.mod && "active"]}
        phx-click="source_tab"
        phx-value-tab={s.mod}
        title={"Source of #{Format.name(s.mod, @syntax)}"}
      >
        <span class="mono">{Format.name(s.mod, @syntax)}</span>
      </button>
      <button
        type="button"
        class="src-close"
        phx-click="close_source"
        phx-value-mod={s.mod}
        aria-label={"Close the source of #{Format.name(s.mod, @syntax)}"}
        title="Close"
      >
        ×
      </button>
    </span>
    """
  end

  attr :sources, :list, required: true
  attr :current, :atom, default: nil
  attr :syntax, :atom, default: :erlang

  @doc "The source shown, if any."
  def panel(assigns) do
    assigns = assign(assigns, s: Enum.find(assigns.sources, &(&1.mod == assigns.current)))

    ~H"""
    <section :if={@s} class="src-panel" role="tabpanel">
      <div class="src-head">
        <h2 class="mono">{Format.name(@s.mod, @syntax)}</h2>
        <span :if={@s.source.path} class="mono muted small">{@s.source.path}</span>
      </div>
      <p :if={@s.source.kind == :debug_info} class="notice small">
        The source file isn't on the node, so this is Erlang rebuilt from the module's debug info:
        names, clauses and calls are as compiled, without comments or macros.
      </p>
      <p :if={@s.source.kind == :local} class="notice small">
        The source file isn't on the node, so this is the file on this computer, from the
        application's source folder in <.link navigate="/settings">Settings</.link>.
        It may differ from the version the node runs.
      </p>
      <p :if={@s.source.kind == :none} class="notice">
        No source to show: {ModuleSource.reason(@s.source.reason)}.
        A folder with the application's source on this computer can be set in <.link navigate="/settings">Settings</.link>.
      </p>
      <p :if={@s.source.kind == :error} class="error">{@s.source.reason}</p>
      <p :if={@s.source[:truncated]} class="notice small">
        Only the first 2 MB are shown.
      </p>
      <div :if={@s.lines != []} class="src-code mono">
        <pre class="src-nos" aria-hidden="true">{Enum.join(1..length(@s.lines), "\n")}</pre>
        <pre class="src-text"><code
          id={"src-#{@s.mod}"}
          class={"language-#{language(@s.source)}"}
          phx-hook="Highlight"
          phx-update="ignore"
        >{@s.source.text}</code></pre>
      </div>
    </section>
    """
  end

  @doc """
  The Highlight.js language of a source: `"elixir"` for a `.ex` or `.exs`
  file (on the node or local), `"erlang"` for an Erlang file or source
  rebuilt from debug info (always Erlang), else `"plaintext"`.
  """
  def language(%{kind: :debug_info}), do: "erlang"

  def language(%{kind: kind, path: path}) when kind in [:file, :local] and is_binary(path) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] -> "elixir"
      ext when ext in [".erl", ".hrl", ".escript"] -> "erlang"
      _ -> "plaintext"
    end
  end

  def language(_source), do: "plaintext"
end
