defmodule BeamdashWeb.HelpTip do
  @moduledoc """
  A `?` mark that shows a plain-language note about a field, with a link to
  its entry in the Erlang/OTP documentation.
  """
  use Phoenix.Component

  attr :label, :string, required: true
  attr :text, :string, required: true
  attr :href, :string, required: true

  def tip(assigns) do
    assigns = assign(assigns, :id, "help-#{:erlang.phash2(assigns.text)}")

    ~H"""
    <button
      type="button"
      class="help-tip"
      popovertarget={@id}
      style={"anchor-name: --#{@id}"}
      aria-label={"Help: #{@label}"}
      aria-describedby={@id}
    >
      ?
    </button>
    <span id={@id} class="help-tip-body" popover style={"position-anchor: --#{@id}"}>
      {@text}
      <a href={@href} target="_blank" rel="noopener">OTP docs</a>
    </span>
    """
  end
end
