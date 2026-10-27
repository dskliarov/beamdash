defmodule BeamdashWeb.LogsTable do
  @moduledoc """
  The Logs tab's presentational pieces (`BeamdashWeb.LogsLive`): the source
  bar (`source_bar/1`) and the table (`table/1`), the `.log` grid of the
  Trace page, one streamed item per row. A group row (`count > 1`) shows a
  `×N` badge and Expand / Show all like this / Copy / Download buttons;
  clicking it expands it into its original lines, with the masked parts
  (`Beamdash.Logs.Group.mask_spans/1`) marked, and a "+N newer" button
  while newer similar lines have joined it since. Clicking a single line (or
  one of an expanded group's lines) opens its full message and metadata.
  While a node is attached, a line's pid opens that process on the
  Processes tab.
  """
  use Phoenix.Component

  alias Beamdash.Format
  alias Beamdash.Logs.Filter
  alias Beamdash.Target

  attr :info, :map, required: true, doc: "`Beamdash.Logs.info/1`"
  attr :node, :atom, default: nil
  attr :view, :atom, required: true, doc: ":live or :previous"

  @doc "Where the lines come from, the stream's state, and the Live / Previous container switch."
  def source_bar(assigns) do
    ~H"""
    <div class="active-traces logs-source">
      <.source info={@info} node={@node} />
      <span :if={@info.status == :streaming} class="muted small">streaming</span>
      <span :if={match?({:ended, _}, @info.status)} class="muted small">
        {ended(@info.status)}
      </span>
      <button
        :if={match?({:ended, _}, @info.status)}
        type="button"
        class="secondary"
        phx-click="reconnect"
      >
        Reconnect
      </button>
      <div
        :if={@info.source == :kubectl or @view == :previous}
        class="seg"
        role="group"
        aria-label="Container"
      >
        <button
          :for={{value, label} <- [{"live", "Live"}, {"previous", "Previous container"}]}
          type="button"
          class={["seg-btn", Atom.to_string(@view) == value && "active"]}
          aria-pressed={to_string(Atom.to_string(@view) == value)}
          phx-click="view"
          phx-value-view={value}
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  attr :info, :map, required: true
  attr :node, :atom, default: nil

  defp source(%{info: %{source: :kubectl}} = assigns) do
    ~H"""
    <span>
      kubectl logs <code>{kubectl_target(@info.kubectl)}</code>
      <span :if={@info.kubectl[:namespace]} class="muted small">
        in {@info.kubectl[:namespace]}
      </span><span :if={@info.level}>, then logger on <code>{@node}</code>, level
      <code>{@info.level}</code></span>
    </span>
    """
  end

  defp source(%{info: %{source: :direct}} = assigns) do
    ~H"""
    <span>
      logger on <code>{@node}</code><span :if={@info.level}>, level <code>{@info.level}</code></span>
    </span>
    """
  end

  defp source(assigns) do
    ~H"""
    <strong>Logs</strong>
    """
  end

  defp kubectl_target(%{pod: pod, container: c}) when is_binary(c) and c != "", do: "#{pod}/#{c}"
  defp kubectl_target(k), do: "#{k[:pod]}"

  defp ended({:ended, code}) when is_integer(code), do: "Stream ended (exit #{code})"
  defp ended({:ended, reason}), do: "Stream ended: #{Format.error(reason)}"

  attr :rows, :any, required: true, doc: "the `:rows` stream"
  attr :filter, :map, required: true, doc: "the parsed text filter, for highlighting"

  attr :node, :atom,
    default: nil,
    doc: "the attached node, when connected: pids link to its processes"

  def table(assigns) do
    ~H"""
    <div class="log logs-table" role="table" aria-label="Log lines">
      <div class="log-cols logs-cols log-head" role="row">
        <span role="columnheader">Time (UTC)</span>
        <span role="columnheader">Level</span>
        <span role="columnheader">Process</span>
        <span role="columnheader">Where</span>
        <span role="columnheader">Message</span>
        <span role="columnheader"><span class="sr-only">Actions</span></span>
      </div>
      <div id="logs-rows" phx-update="stream" role="rowgroup">
        <div
          :for={{dom_id, row} <- @rows}
          id={dom_id}
          class={["log-item", (row.expanded? or open?(row)) && "open"]}
        >
          <div
            class={["log-cols logs-cols log-row", level_class(row.entry.level)]}
            role="row"
            tabindex="0"
            aria-expanded={to_string(row.expanded? or open?(row))}
            phx-click={if row.count > 1, do: "toggle_row", else: "toggle_entry"}
            phx-keydown={if row.count > 1, do: "toggle_row", else: "toggle_entry"}
            phx-key="Enter"
            phx-value-id={if row.count > 1, do: row.id, else: row.entry.id}
            phx-value-row={row.id}
            phx-value-entry={row.entry.id}
            title={row_title(row)}
          >
            <span class="mono" role="cell" title={first_at(row)}>{time(row.entry.at)}</span>
            <span role="cell"><.level level={row.entry.level} /></span>
            <span class="mono" role="cell"><.pid pid={row.entry.pid} node={@node} /></span>
            <span class="mono" role="cell">{row.entry.where}</span>
            <span class="logs-msg" role="cell" title={row.entry.message}>
              {highlighted(first_line(row.entry.message), @filter)}
            </span>
            <span class="logs-actions" role="cell">
              <%= if row.count > 1 do %>
                <span class="count-badge" title={"#{row.count} similar lines"}>×{row.count}</span>
                <button
                  type="button"
                  class="secondary small-btn"
                  phx-click="toggle_row"
                  phx-value-id={row.id}
                  phx-value-entry={row.entry.id}
                  aria-expanded={to_string(row.expanded?)}
                >
                  {if row.expanded?, do: "Collapse", else: "Expand"}
                </button>
                <button
                  :if={row.expanded? and row.newer > 0}
                  type="button"
                  class="small-btn"
                  phx-click="refresh_row"
                  phx-value-id={row.id}
                  phx-value-entry={row.entry.id}
                  title="List the newer lines too"
                >
                  +{row.newer} newer — refresh
                </button>
                <button
                  type="button"
                  class="secondary small-btn"
                  phx-click="like"
                  phx-value-id={row.id}
                  phx-value-entry={row.entry.id}
                >
                  Show all like this
                </button>
                <button
                  type="button"
                  class="secondary small-btn"
                  phx-click="export"
                  phx-value-id={row.id}
                  phx-value-entry={row.entry.id}
                  phx-value-mode="copy"
                  title="Copy these lines"
                >
                  Copy
                </button>
                <button
                  type="button"
                  class="secondary small-btn"
                  phx-click="export"
                  phx-value-id={row.id}
                  phx-value-entry={row.entry.id}
                  phx-value-mode="download"
                  title="Download these lines"
                  aria-label="Download these lines"
                >
                  ⤓
                </button>
              <% end %>
            </span>
          </div>
          <.details :if={row.count == 1 and open?(row)} entry={row.entry} node={@node} />
          <div :if={row.expanded?} class="logs-lines" role="rowgroup">
            <div :for={{e, spans} <- row.lines} class={["logs-line", e.id in row.open && "open"]}>
              <div
                class={["log-cols logs-cols log-row", level_class(e.level)]}
                role="row"
                tabindex="0"
                aria-expanded={to_string(e.id in row.open)}
                phx-click="toggle_entry"
                phx-keydown="toggle_entry"
                phx-key="Enter"
                phx-value-id={e.id}
                phx-value-row={row.id}
              >
                <span class="mono" role="cell">{time(e.at)}</span>
                <span role="cell"><.level level={e.level} /></span>
                <span class="mono" role="cell"><.pid pid={e.pid} node={@node} /></span>
                <span class="mono" role="cell">{e.where}</span>
                <span class="logs-line-msg" role="cell">{masked(spans)}</span>
                <span role="cell"></span>
              </div>
              <.details :if={e.id in row.open} entry={e} node={@node} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :node, :atom, default: nil

  defp details(assigns) do
    ~H"""
    <div class="detail log-detail" role="region">
      <pre>{@entry.message}</pre>
      <table class="props">
        <tr>
          <th>time</th>
          <td class="mono">{if @entry.at, do: DateTime.to_iso8601(@entry.at), else: "—"}</td>
        </tr>
        <tr :if={@entry.level}>
          <th>level</th>
          <td class="mono">{@entry.level}</td>
        </tr>
        <tr :if={@entry.pid}>
          <th>pid</th>
          <td class="mono"><.pid pid={@entry.pid} node={@node} /></td>
        </tr>
        <tr :if={@entry.where}>
          <th>where</th>
          <td class="mono">{@entry.where}</td>
        </tr>
        <tr :for={{k, v} <- @entry.meta}>
          <th>{k}</th>
          <td class="mono"><pre>{v}</pre></td>
        </tr>
      </table>
    </div>
    """
  end

  attr :pid, :string, default: nil
  attr :node, :atom, default: nil

  # A pid opens the process on the Processes tab while a node is attached
  defp pid(assigns) do
    assigns = assign(assigns, :href, process_href(assigns.pid, assigns.node))

    ~H"""
    <.link :if={@href} navigate={@href} class="proc-link" title="Open this process">{@pid}</.link><span :if={
      !@href
    }>{@pid}</span>
    """
  end

  # Pids from the logger handler are printed as this node sees them
  # ("<25518.86.0>"); pids in text lines as the target printed them
  # ("<0.86.0>", "#PID<0.86.0>"), which localize_pid/2 rewrites.
  defp process_href(pid, node) when is_binary(pid) and node != nil do
    bare = String.replace_prefix(pid, "#PID", "")

    if Regex.match?(~r/^<\d+\.\d+\.\d+>$/, bare),
      do: "/?pid=" <> URI.encode_www_form(Target.localize_pid(bare, node))
  end

  defp process_href(_pid, _node), do: nil

  attr :level, :atom, default: nil

  defp level(assigns) do
    ~H"""
    <span :if={@level} class={"lvl lvl-#{@level}"}>{@level}</span>
    """
  end

  # The message with the filter's terms in <mark>. Built as iodata (a HEEx
  # :for would add whitespace inside the text); every segment of log text
  # goes through Phoenix.HTML.html_escape/1, only the tags are literal.
  defp highlighted(text, filter) do
    {:safe,
     Enum.map(Filter.highlight(text, filter), fn
       {:mark, s} -> ["<mark>", escape(s), "</mark>"]
       {:text, s} -> escape(s)
     end)}
  end

  # a message's spans (`Group.mask_spans/1`, worked out when the group was
  # expanded) with the variable parts (what grouping masks) marked
  defp masked(spans) do
    {:safe,
     Enum.map(spans, fn
       {:var, s} -> [~s(<span class="var">), escape(s), "</span>"]
       {:text, s} -> escape(s)
     end)}
  end

  defp escape(text) do
    {:safe, iodata} = Phoenix.HTML.html_escape(text)
    iodata
  end

  defp open?(row), do: row.entry.id in row.open

  defp row_title(%{count: n, expanded?: true}) when n > 1, do: "Collapse"
  defp row_title(%{count: n}) when n > 1, do: "Show the #{n} lines"
  defp row_title(_row), do: "Show details"

  defp first_at(%{count: n, first_at: at}) when n > 1 and at != nil,
    do: "first at #{time(at)}"

  defp first_at(_row), do: nil

  defp first_line(message) do
    case String.split(message, "\n", parts: 2) do
      [line, _rest] -> line <> " …"
      [line] -> line
    end
  end

  # error and above share one colour
  defp level_class(level) when level in [:emergency, :alert, :critical, :error],
    do: "lvl-row-error"

  defp level_class(_level), do: nil

  @doc "`HH:MM:SS.mmm` (UTC), or `—` without a time."
  def time(nil), do: "—"

  def time(%DateTime{} = at) do
    %{hour: h, minute: m, second: s, microsecond: {us, _}} = DateTime.shift_zone!(at, "Etc/UTC")
    "#{pad(h, 2)}:#{pad(m, 2)}:#{pad(s, 2)}.#{pad(div(us, 1000), 3)}"
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
