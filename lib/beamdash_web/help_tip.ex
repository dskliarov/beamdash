defmodule BeamdashWeb.HelpTip do
  @moduledoc """
  A `?` mark that shows a plain-language note about a field, with a link to
  its entry in the Erlang/OTP documentation.
  """
  use Phoenix.Component

  attr :text, :string, required: true
  attr :href, :string, required: true

  def tip(assigns) do
    ~H"""
    <span class="help-tip" tabindex="0">
      ?
      <span class="help-tip-body" role="tooltip">
        {@text}
        <a href={@href} target="_blank" rel="noopener">OTP docs</a>
      </span>
    </span>
    """
  end
end
