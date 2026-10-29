defmodule BeamdashWeb.CodeEditor do
  @moduledoc "CodeMirror editor synchronized with a LiveView form and explicit document revisions."
  use Phoenix.Component

  attr :id, :string, required: true
  attr :source, :string, required: true
  attr :language, :string, required: true
  attr :revision, :integer, default: 0
  attr :name, :string, default: "source"
  attr :label, :string, default: "Module source code"

  def editor(assigns) do
    ~H"""
    <div
      id={@id}
      class="module-codemirror"
      phx-hook="CodeMirrorEditor"
      data-language={@language}
      data-revision={@revision}
    >
      <div id={@id <> "-view"} class="codemirror-host" phx-update="ignore"></div>
      <textarea
        id={@id <> "-input"}
        class="codemirror-fallback"
        name={@name}
        aria-label={@label}
        rows="24"
        spellcheck="false"
        autocapitalize="off"
        autocomplete="off"
        autocorrect="off"
        phx-debounce="150"
      >{@source}</textarea>
    </div>
    """
  end
end
