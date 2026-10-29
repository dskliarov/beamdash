defmodule BeamdashWeb.SourceBrowser do
  use Phoenix.Component

  attr :browser, :map, required: true

  def picker(assigns) do
    ~H"""
    <section class="dir-browser module-source-browser" aria-label="Local source files">
      <div class="dir-browser-head">
        <strong>Browse local source</strong>
        <button type="button" class="secondary" phx-click="source_browse_up">Up</button>
        <button type="button" class="secondary" phx-click="source_browse_close">Cancel</button>
      </div>
      <p class="muted small">
        Folders on the machine running Beamdash. Choose an .ex, .exs or .erl file to load into the editor.
      </p>
      <form phx-submit="source_browse_path" class="source-browser-path">
        <input name="path" value={@browser.path} aria-label="Local folder path" required />
        <button type="submit" class="secondary">Go</button>
      </form>
      <p :if={@browser.error} role="alert">{@browser.error}</p>
      <ul class="dir-browser-list">
        <li :for={name <- @browser.subdirs}>
          <button
            type="button"
            class="dir-browser-entry"
            phx-click="source_browse_into"
            phx-value-name={name}
          >📁 {name}/</button>
        </li>
        <li :for={name <- @browser.files}>
          <button
            type="button"
            class="dir-browser-entry"
            phx-click="source_browse_pick"
            phx-value-name={name}
          >📄 {name}</button>
        </li>
      </ul>
      <p
        :if={@browser.subdirs == [] and @browser.files == [] and @browser.error == nil}
        class="muted small"
      >
        No folders or source files here.
      </p>
    </section>
    """
  end
end
