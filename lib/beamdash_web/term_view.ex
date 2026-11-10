defmodule BeamdashWeb.TermView do
  @moduledoc """
  An Erlang or Elixir term as raw text, as pretty-printed text with coloured
  tokens, or as a collapsible tree. `view_switch/1` picks the view.
  """
  use Phoenix.Component

  alias Beamdash.Format
  alias BeamdashWeb.TermTree

  @token ~r/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|#(?:Ref|Fun|PID|Port)<[^>]*>|<\d+\.\d+\.\d+>|<<|>>|#\{|%\{|#[a-z]\w*\{|%[A-Z][\w.]*\{|[{}\[\](),]|:[A-Za-z_]\w*|[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/

  @openers %{"{" => :curly, "[" => :square, "(" => :round, "<<" => :bin}
  @closers %{"}" => :curly, "]" => :square, ")" => :round, ">>" => :bin}
  @classes %{
    curly: "tok-curly",
    square: "tok-square",
    round: "tok-round",
    bin: "tok-bin",
    map: "tok-map"
  }

  @doc "The view named by an event value. Anything unknown is Pretty."
  def parse_view("raw"), do: :raw
  def parse_view("tree"), do: :tree
  def parse_view(_), do: :pretty

  attr :view, :atom, required: true
  attr :event, :string, default: "term_view"
  attr :target, :any, default: nil

  def view_switch(assigns) do
    ~H"""
    <nav class="seg term-view" role="tablist" aria-label="Output format">
      <button
        :for={{view, label} <- [raw: "Raw", pretty: "Pretty", tree: "Tree"]}
        type="button"
        role="tab"
        class={["seg-btn", @view == view && "active"]}
        aria-selected={to_string(@view == view)}
        phx-click={@event}
        phx-value-view={view}
        phx-target={@target}
      >
        {label}
      </button>
    </nav>
    """
  end

  attr :value, :any, required: true
  attr :syntax, :atom, required: true
  attr :view, :atom, required: true

  def term(%{view: :tree} = assigns) do
    ~H"""
    <div class="term-tree"><TermTree.tree value={@value} syntax={@syntax} /></div>
    """
  end

  def term(%{view: :raw} = assigns) do
    ~H"""
    <pre class="term-text">{Format.pretty(@value, @syntax, 1_000_000)}</pre>
    """
  end

  def term(assigns) do
    ~H"""
    <.text segments={[{:term, Format.pretty(@value, @syntax)}]} />
    """
  end

  attr :segments, :list,
    required: true,
    doc: "`{:term, text}` pieces are coloured, `{:text, text}` pieces are plain"

  def text(assigns) do
    assigns = assign(assigns, :pieces, Enum.flat_map(assigns.segments, &colour/1))

    ~H"""
    <pre class="term-text"><.spans segments={@pieces} /></pre>
    """
  end

  defp colour({:term, text}), do: highlight(text)
  defp colour({:text, text}), do: [{nil, text}]

  attr :segments, :list, required: true

  defp spans(assigns) do
    ~H"""
    <span :for={{class, text} <- @segments} class={class}>{text}</span>
    """
  end

  @doc """
  Splits pretty-printed term text into `{class, text}` pieces. A bracket takes
  the colour of the bracket it closes, so the closing brace of a map is map-coloured.
  """
  def highlight(text) do
    {pieces, _stack, cursor} =
      @token
      |> Regex.scan(text, return: :index)
      |> Enum.reduce({[], [], 0}, fn [{start, len}], {acc, stack, cursor} ->
        {piece, stack} = color(binary_part(text, start, len), stack)
        gap = {nil, binary_part(text, cursor, start - cursor)}
        {[piece, gap | acc], stack, start + len}
      end)

    [{nil, binary_part(text, cursor, byte_size(text) - cursor)} | pieces]
    |> Enum.reverse()
    |> Enum.reject(&match?({_, ""}, &1))
  end

  defp color(token, stack) do
    cond do
      kind = opener(token) ->
        {{@classes[kind], token}, [kind | stack]}

      Map.has_key?(@closers, token) ->
        {kind, rest} = close(token, stack)
        {{@classes[kind], token}, rest}

      true ->
        {{word_class(token), token}, stack}
    end
  end

  defp opener(token) do
    cond do
      Map.has_key?(@openers, token) -> @openers[token]
      token in ["\#{", "%{"] -> :map
      String.starts_with?(token, "%") and String.ends_with?(token, "{") -> :map
      String.starts_with?(token, "#") and String.ends_with?(token, "{") -> :curly
      true -> nil
    end
  end

  defp close("}", [:map | rest]), do: {:map, rest}
  defp close(token, [_ | rest]), do: {@closers[token], rest}
  defp close(token, []), do: {@closers[token], []}

  defp word_class("\"" <> _), do: "tok-string"
  defp word_class("," <> _), do: "tok-comma"
  defp word_class("#" <> _), do: "tok-ref"
  defp word_class("<" <> _), do: "tok-ref"
  defp word_class(_atom), do: "tok-atom"
end
