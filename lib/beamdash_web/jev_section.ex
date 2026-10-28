defmodule BeamdashWeb.JevSection do
  @moduledoc """
  The Jev section at the bottom of the Processes and GC panels: one row
  with the button and how much history is collected, then the answer
  (with the runner-up when it is close) and, folded away, what is sent.
  """
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @doc """
  Whether Jev's UI shows: enabled in the configuration, an API key set, and
  the Settings switch on. Otherwise nothing of Jev shows on any tab.
  """
  def show?(enabled), do: enabled == true and Beamdash.Jev.available?()

  attr :id, :string, required: true
  attr :event, :string, required: true, doc: "phx-click event that starts an analysis"
  attr :title, :string, required: true
  attr :sends, :string, required: true, doc: "what the request contains, in one sentence"
  attr :enabled, :boolean, required: true
  attr :configured, :boolean, required: true
  attr :busy, :boolean, required: true
  attr :readiness, :any, required: true, doc: "{:ready, s} | {:collecting, s, needed}"
  attr :advice, :map, default: nil
  attr :error, :string, default: nil
  attr :evidence, :map, default: nil

  attr :basis, :string,
    default: nil,
    doc: "what an answer was based on, instead of samples/window"

  def section(assigns) do
    assigns =
      assign(assigns,
        ready: match?({:ready, _}, assigns.readiness),
        usable: assigns.enabled and assigns.configured,
        name: Beamdash.Jev.name(),
        backend: Beamdash.Jev.backend()
      )

    ~H"""
    <section :if={show?(@enabled)} class="jev-section" id={@id} aria-label={@title}>
      <div class="section-head">
        <h4>{@title}</h4>
        <span class="jev-actions">
          <span :if={@usable and not @ready and not @busy} class="muted small" role="status">
            {collecting_text(@readiness)}
          </span>
          <button
            :if={@usable}
            class="small-btn"
            phx-click={@event}
            disabled={@busy or not @ready}
            title={
              if @ready,
                do: "Ask #{@name} which investigation should come next",
                else: "Keep this process selected while history is collected"
            }
          >
            {cond do
              @busy -> "Analyzing…"
              @advice -> "Analyze again"
              true -> "Analyze"
            end}
          </button>
        </span>
      </div>

      <p :if={@error} class="error small" role="alert">{@error}</p>

      <div :if={@advice} class="jev-advice" role="status">
        <p class="jev-answer">
          <strong>{@advice.title}</strong>
          <span :if={@advice.alternative} class="muted">
            or {@advice.alternative.label}
          </span>
        </p>
        <p class="small">{@advice.description}</p>
        <p :if={@advice.alternative} class="small muted">
          The measurements fit both about equally well.
        </p>
        <table class="kv jev-ranking">
          <tr :for={r <- Enum.take(@advice.ranking, 4)}>
            <th>{r.label}</th>
            <td>
              <span class="jev-bar" style={"width: #{round(r.probability * 100)}%"}></span>
              {round(r.probability * 100)}%
            </td>
          </tr>
        </table>
        <p class="muted small">
          {@basis || "Based on #{@advice.samples} samples over #{@advice.window_s} s"}, at {Calendar.strftime(
            @advice.at,
            "%H:%M:%S"
          )} UTC · {@advice.model} · a suggestion, not a diagnosis; nothing is changed.
        </p>
      </div>

      <%!-- stays open across the panel's 1 s refresh --%>
      <details class="jev-sent" id={@id <> "-sent"} phx-mounted={JS.ignore_attributes(["open"])}>
        <summary class="small muted">What is sent to {Beamdash.Jev.destination(@backend)}</summary>
        <p :if={@backend == :jev} class="small muted">
          {@sends} Never names, pids, modules, stacks, messages or state. Sent only when you click, to TypeSafe's API; its docs do not state how long requests are kept. Calls may be charged.
        </p>
        <p :if={@backend == :kev} class="small muted">
          {@sends} Never names, pids, modules, stacks, messages or state. Sent only when you click, to the Kev server at {Beamdash.Jev.endpoint(
            :kev
          )}.
        </p>
        <pre :if={@evidence} class="small">{Jason.encode!(@evidence, pretty: true)}</pre>
      </details>
    </section>
    """
  end

  defp collecting_text({:collecting, s, needed, unit}),
    do: "collecting · #{s} of #{needed} #{unit}"

  defp collecting_text({:collecting, s, needed}), do: "collecting history · #{s} of #{needed} s"
  defp collecting_text(_), do: ""
end
