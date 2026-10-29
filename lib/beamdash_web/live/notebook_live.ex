defmodule BeamdashWeb.NotebookLive do
  use Phoenix.LiveView
  alias Beamdash.{Console, Format, Notebook, NotebookStore, Target}

  @impl true
  def mount(_, _, socket) do
    %{status: status, node: node} = Target.status()
    if connected?(socket), do: Target.subscribe()

    {:ok,
     socket
     |> assign(
       status: status,
       node: node,
       notebook: Notebook.new(),
       filename: "untitled.livemd",
       saved_name: nil,
       version: :new,
       dirty: false,
       files: [],
       error: nil,
       notice: nil,
       sessions: %{},
       pending: nil,
       queue: [],
       results: %{},
       timeout: 30_000,
       include_outputs: false
     )
     |> allow_upload(:notebook_file,
       accept: :any,
       max_entries: 1,
       max_file_size: 2 * 1024 * 1024
     )
     |> list_files()}
  end

  defp list_files(socket) do
    case NotebookStore.list() do
      {:ok, files} -> assign(socket, files: files)
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  @impl true
  def handle_event("new_notebook", _, socket) do
    {:noreply,
     socket
     |> close_sessions()
     |> assign(
       notebook: Notebook.new(),
       filename: "untitled.livemd",
       saved_name: nil,
       version: :new,
       dirty: false,
       results: %{},
       error: nil,
       notice: nil
     )
     |> push_event("notebook-replaced", %{})}
  end

  def handle_event("refresh_notebooks", _, socket), do: {:noreply, list_files(socket)}

  def handle_event("filename", %{"filename" => name}, socket),
    do: {:noreply, assign(socket, filename: name)}

  def handle_event("rename_notebook", %{"title" => title}, %{assigns: %{pending: nil}} = socket),
    do:
      {:noreply,
       assign(socket, notebook: Notebook.rename(socket.assigns.notebook, title), dirty: true)}

  def handle_event("include_outputs", params, socket),
    do:
      {:noreply,
       assign(socket, include_outputs: params["include_outputs"] == "true", dirty: true)}

  def handle_event("timeout", %{"timeout" => timeout}, socket)
      when timeout in ~w(5000 15000 30000 60000),
      do: {:noreply, assign(socket, timeout: String.to_integer(timeout))}

  def handle_event("open_notebook", %{"name" => name}, socket) do
    case NotebookStore.load(name) do
      {:ok, source, version} ->
        case Notebook.from_livemd(source) do
          {:ok, notebook} ->
            {:noreply,
             socket
             |> close_sessions()
             |> assign(
               notebook: notebook,
               filename: name,
               saved_name: name,
               version: version,
               dirty: false,
               results: %{},
               error: nil,
               notice: "Opened #{name}. No cells have been executed."
             )
             |> push_event("notebook-replaced", %{})}

          {:error, error} ->
            {:noreply, assign(socket, error: error)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, error: Format.error(reason))}
    end
  end

  def handle_event("save_notebook", %{"filename" => name}, socket) do
    expected = if name == socket.assigns.saved_name, do: socket.assigns.version, else: :new
    source = export_source(socket)

    case NotebookStore.save(name, source, expected) do
      {:ok, version} ->
        {:noreply,
         socket
         |> assign(
           filename: name,
           saved_name: name,
           version: version,
           dirty: false,
           error: nil,
           notice: "Saved #{name}."
         )
         |> push_event("notebook-saved", %{})
         |> list_files()}

      {:error, reason} ->
        {:noreply, assign(socket, error: Format.error(reason))}
    end
  end

  def handle_event("download_notebook", _, socket) do
    source = export_source(socket)

    if byte_size(source) <= 2 * 1024 * 1024 do
      name =
        if Path.extname(socket.assigns.filename) == ".livemd",
          do: Path.basename(socket.assigns.filename),
          else: "notebook.livemd"

      {:noreply, push_event(socket, "notebook-download", %{name: name, text: source})}
    else
      {:noreply,
       assign(socket,
         error: "Notebook with outputs exceeds the 2 MiB limit. Exclude outputs or remove cells."
       )}
    end
  end

  def handle_event("validate_upload", _, socket), do: {:noreply, socket}

  def handle_event("import_notebook", _, socket) do
    results =
      consume_uploaded_entries(socket, :notebook_file, fn %{path: path}, entry ->
        source =
          if Path.extname(entry.client_name) == ".livemd",
            do: File.read!(path),
            else: :invalid_extension

        {:ok, {entry.client_name, source}}
      end)

    case results do
      [{_, :invalid_extension}] ->
        {:noreply, assign(socket, error: "Choose a .livemd file to import.")}

      [{name, source}] ->
        case Notebook.from_livemd(source) do
          {:ok, notebook} ->
            {:noreply,
             socket
             |> close_sessions()
             |> assign(
               notebook: notebook,
               filename: Path.basename(name),
               saved_name: nil,
               version: :new,
               dirty: true,
               results: %{},
               error: nil,
               notice: "Imported #{name}. Review cells before running them."
             )
             |> push_event("notebook-replaced", %{})}

          {:error, error} ->
            {:noreply, assign(socket, error: error)}
        end

      _ ->
        {:noreply, assign(socket, error: "Choose a .livemd file to import.")}
    end
  end

  def handle_event("add_cell", %{"kind" => kind}, %{assigns: %{pending: nil}} = socket)
      when kind in ~w(elixir erlang markdown section),
      do:
        {:noreply,
         assign(socket,
           notebook: Notebook.append(socket.assigns.notebook, String.to_existing_atom(kind)),
           dirty: true
         )}

  def handle_event("delete_cell", %{"id" => id}, %{assigns: %{pending: nil}} = socket),
    do:
      {:noreply,
       assign(socket,
         notebook: Notebook.remove(socket.assigns.notebook, id),
         dirty: true,
         results: stale(socket.assigns.results)
       )}

  def handle_event(
        "edit_cell",
        %{"cell_id" => id, "source" => source},
        %{assigns: %{pending: nil}} = socket
      ) do
    notebook = Notebook.update(socket.assigns.notebook, id, source, nil)

    results =
      if notebook == socket.assigns.notebook,
        do: socket.assigns.results,
        else: stale(socket.assigns.results)

    {:noreply,
     assign(socket,
       notebook: notebook,
       results: results,
       dirty: notebook != socket.assigns.notebook or socket.assigns.dirty
     )}
  end

  def handle_event(
        "complete",
        %{"cell_id" => id, "token" => token},
        %{assigns: %{status: :connected, pending: nil}} = socket
      ) do
    block = Enum.find(socket.assigns.notebook.blocks, &(&1.id == id))

    items =
      if block && block.executable && current_target?(socket),
        do: Console.complete(socket.assigns.node, block.language, token),
        else: []

    {:reply, %{items: items}, socket}
  end

  def handle_event("complete", _, socket), do: {:reply, %{items: []}, socket}

  def handle_event("run_cell", %{"id" => id}, %{assigns: %{pending: nil}} = socket),
    do: {:noreply, run_cell(socket, id)}

  def handle_event("run_all", _, %{assigns: %{pending: nil}} = socket) do
    queue =
      for block <- socket.assigns.notebook.blocks,
          block.executable,
          String.trim(block.source) != "",
          do: block.id

    {:noreply,
     socket |> close_sessions() |> assign(queue: queue, results: %{}, error: nil) |> run_next()}
  end

  def handle_event("reset_notebook_runtime", _, socket),
    do:
      {:noreply,
       socket
       |> close_sessions()
       |> assign(
         results: stale(socket.assigns.results),
         notice: "Notebook sessions reset. Side effects are not undone."
       )}

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp run_cell(socket, id) do
    block = Enum.find(socket.assigns.notebook.blocks, &(&1.id == id))

    cond do
      block == nil or not block.executable ->
        assign(socket,
          queue: [],
          error: "This block cannot be executed by the connected-node runtime."
        )

      not current_target?(socket) ->
        assign(socket, queue: [], error: "Connect to a node before running cells.")

      byte_size(block.source) > 32768 ->
        assign(socket, queue: [], error: "Code cells must be at most 32 KiB to execute.")

      true ->
        session =
          case socket.assigns.sessions[block.language] do
            nil -> Console.start(socket.assigns.node, self(), block.language)
            pid -> {:ok, pid}
          end

        case session do
          {:ok, pid} ->
            ref = make_ref()
            node = socket.assigns.node
            timeout = socket.assigns.timeout
            code = block.source

            socket
            |> assign(
              sessions: Map.put(socket.assigns.sessions, block.language, pid),
              pending: %{id: id, ref: ref},
              error: nil,
              results:
                Map.put(socket.assigns.results, id, %{status: :running, output: "", result: ""})
            )
            |> start_async({:notebook_cell, ref}, fn -> Console.eval(node, pid, code, timeout) end)

          {:error, reason} ->
            assign(socket, queue: [], error: Format.error(reason))
        end
    end
  end

  defp run_next(%{assigns: %{queue: []}} = socket), do: socket

  defp run_next(socket) do
    [id | rest] = socket.assigns.queue
    socket |> assign(queue: rest) |> run_cell(id)
  end

  @impl true
  def handle_async(
        {:notebook_cell, ref},
        result,
        %{assigns: %{pending: %{ref: ref, id: id}}} = socket
      ) do
    response =
      case result do
        {:ok, {:ok, response}} when is_map(response) -> response
        {:ok, {:error, reason}} -> %{status: :error, output: "", result: Format.error(reason)}
        {:exit, reason} -> %{status: :error, output: "", result: Format.error(reason)}
      end

    socket =
      assign(socket,
        pending: nil,
        results: Map.put(socket.assigns.results, id, response),
        dirty: socket.assigns.dirty or socket.assigns.include_outputs
      )

    {:noreply,
     if(response.status == :ok,
       do: run_next(socket),
       else: assign(socket, queue: [], notice: "Execution stopped at the failed cell.")
     )}
  end

  def handle_async(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do:
      {:noreply,
       socket
       |> close_sessions()
       |> assign(status: :connected, node: node, results: stale(socket.assigns.results))}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do:
      {:noreply,
       socket
       |> close_sessions()
       |> assign(status: :disconnected, node: nil, results: stale(socket.assigns.results))}

  def handle_info(_, socket), do: {:noreply, socket}

  defp current_target?(socket),
    do:
      socket.assigns.status == :connected and
        Target.status() == %{status: :connected, node: socket.assigns.node}

  defp export_source(socket),
    do:
      Notebook.to_livemd(socket.assigns.notebook,
        outputs: if(socket.assigns.include_outputs, do: socket.assigns.results, else: %{})
      )

  defp stale(results),
    do: Map.new(results, fn {id, result} -> {id, %{result | status: :stale}} end)

  defp close_sessions(socket) do
    socket =
      if socket.assigns.pending,
        do: cancel_async(socket, {:notebook_cell, socket.assigns.pending.ref}),
        else: socket

    Enum.each(socket.assigns.sessions, fn {_, pid} -> Console.stop(pid) end)
    assign(socket, sessions: %{}, pending: nil, queue: [])
  end

  @impl true
  def terminate(_, socket) do
    Enum.each(socket.assigns.sessions, fn {_, pid} -> Console.stop(pid) end)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="notebook-workspace"
      class="notebook-workspace"
      phx-hook="NotebookFiles"
      data-dirty={to_string(@dirty)}
    >
      <aside class="notebook-library">
        <div class="console-tools">
          <h2>Notebooks</h2><button
            type="button"
            class="secondary small-btn"
            phx-click="refresh_notebooks"
            title="Refresh notebooks"
          >↻</button>
        </div>
        <button
          type="button"
          phx-click="new_notebook"
          data-notebook-confirm={@dirty && "Discard unsaved changes and create a notebook?"}
        >New notebook</button>
        <p class="muted small notebook-folder">{NotebookStore.directory()}</p>
        <ul>
          <li :for={file <- @files}>
            <button
              type="button"
              class={[@saved_name == file && "active"]}
              phx-click="open_notebook"
              phx-value-name={file}
              data-notebook-confirm={@dirty && "Discard unsaved changes and open this notebook?"}
            >{file}</button>
          </li>
        </ul>
        <p :if={@files == []} class="muted small">No saved notebooks yet.</p>
        <form
          phx-change="validate_upload"
          phx-submit="import_notebook"
          data-notebook-confirm={@dirty && "Discard unsaved changes and import this notebook?"}
        >
          <label for={@uploads.notebook_file.ref}>Import Livebook (.livemd)</label>
          <.live_file_input upload={@uploads.notebook_file} accept=".livemd" />
          <p :for={error <- upload_errors(@uploads.notebook_file)} class="error small">{error}</p>
          <p :for={entry <- @uploads.notebook_file.entries}>
            <span>{entry.client_name}</span><span
              :for={error <- upload_errors(@uploads.notebook_file, entry)}
              class="error small"
            >{error}</span>
          </p>
          <button type="submit" class="secondary" disabled={@uploads.notebook_file.entries == []}>Import</button>
        </form>
      </aside>
      <div class="notebook-main">
        <form phx-change="rename_notebook" class="notebook-title">
          <label for="notebook-title">Notebook title</label><input
            id="notebook-title"
            name="title"
            value={@notebook.title}
            disabled={@pending != nil}
            phx-debounce="300"
          />
        </form>
        <div class="console-tools">
          <form phx-change="filename" phx-submit="save_notebook" class="notebook-save">
            <input
              name="filename"
              value={@filename}
              aria-label="Notebook filename"
              placeholder="name.livemd"
            /><button type="submit" phx-disable-with="Saving…">Save</button>
          </form>
          <button type="button" class="secondary" phx-click="download_notebook">Download .livemd</button>
          <span class="muted small" role="status">{if @dirty,
            do: "Unsaved changes",
            else: "Saved / unchanged"}</span>
        </div>
        <form phx-change="include_outputs">
          <label class="small"><input
            type="checkbox"
            name="include_outputs"
            value="true"
            checked={@include_outputs}
          /> Include evaluated text output when saving/exporting</label>
        </form>
        <p :if={@error} class="error" role="alert">{@error}</p>
        <p :if={@notice} class="notice small" role="status">{@notice}</p>
        <p :for={warning <- @notebook.warnings} class="notice small">{warning}</p>
        <p class="notice small">
          Cells run on
          <strong>{if @status == :connected, do: @node, else: "no connected node"}</strong>
          and can change live state. Importing and opening files never runs code. Edits mark results stale. Run all starts fresh language sessions and stops at the first error; individual cells use the current session.
        </p>
        <p class="help small">
          LiveMarkdown (.livemd) source and metadata are preserved. This runtime supports Markdown and Elixir/Erlang code with text outputs. Kino displays, Smart cells, Python, attachments and branching runtimes require Livebook. Dependencies must already be available on the connected node.
        </p>
        <div class="console-tools">
          <button
            type="button"
            phx-click="run_all"
            disabled={@status != :connected or @pending != nil}
          >Run all</button>
          <button type="button" class="secondary" phx-click="reset_notebook_runtime">Reset runtime</button>
          <form phx-change="timeout">
            <label class="small">Cell timeout
            <select name="timeout"><option
              :for={seconds <- [5, 15, 30, 60]}
              value={seconds * 1000}
              selected={@timeout == seconds * 1000}
            >
              {seconds}s
            </option></select></label>
          </form>
        </div>
        <div class="notebook-cells">
          <article
            :for={block <- @notebook.blocks}
            :if={
              block.kind != :markdown or String.trim(block.source) != "" or
                String.trim(block.original) != ""
            }
            id={"notebook-block-#{block.id}"}
            class="notebook-cell"
          >
            <div class="notebook-cell-head">
              <span>{case block.kind do
                :markdown -> "Markdown"
                :output -> "Saved output (not evaluated)"
                _ -> if(block.executable, do: block.language, else: "Preserved / unsupported cell")
              end}</span>
              <div>
                <button
                  :if={block.executable}
                  type="button"
                  phx-click="run_cell"
                  phx-value-id={block.id}
                  disabled={@status != :connected or @pending != nil}
                >Run cell</button><button
                  type="button"
                  class="secondary small-btn"
                  phx-click="delete_cell"
                  phx-value-id={block.id}
                  disabled={@pending != nil}
                  data-notebook-confirm="Delete this block?"
                >Delete</button>
              </div>
            </div>
            <%= if block.kind == :output or block.metadata["livebook_object"] == "smart_cell" do %>
              <pre class="notebook-output">{block.source}</pre>
            <% else %>
              <form phx-change="edit_cell" phx-submit="edit_cell">
                <input type="hidden" name="cell_id" value={block.id} />
                <%= if block.kind == :markdown do %>
                  <div class="notebook-markdown">
                    {Phoenix.HTML.raw(Notebook.markdown_html(block.source))}
                  </div>
                  <details
                    id={"notebook-markdown-#{block.id}"}
                    phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
                  >
                    <summary>Edit Markdown</summary><textarea
                      name="source"
                      rows="5"
                      aria-label="Markdown source"
                      readonly={@pending != nil}
                      phx-debounce="200"
                    >{block.source}</textarea>
                  </details>
                <% else %>
                  <.code_editor block={block} node={@node} busy={@pending != nil} />
                <% end %>
              </form>
            <% end %>
            <div :if={@results[block.id]} class="notebook-result" aria-live="polite">
              <span class="muted small">{@results[block.id].status}</span>
              <pre :if={@results[block.id].output != ""} class="notebook-output">{@results[block.id].output}</pre>
              <pre class={[@results[block.id].status == :error && "error", "notebook-output"]}>{@results[block.id].result}</pre>
            </div>
          </article>
        </div>
        <div class="console-tools">
          <button
            :for={
              {kind, label} <- [
                {:elixir, "+ Elixir"},
                {:erlang, "+ Erlang"},
                {:markdown, "+ Markdown"},
                {:section, "+ Section"}
              ]
            }
            type="button"
            class="secondary"
            phx-click="add_cell"
            phx-value-kind={kind}
            disabled={@pending != nil}
          >{label}</button>
        </div>
      </div>
    </section>
    """
  end

  attr :block, :map, required: true
  attr :node, :any, required: true
  attr :busy, :boolean, required: true

  defp code_editor(assigns) do
    ~H"""
    <div
      id={"notebook-completion-#{@block.id}"}
      phx-hook="ConsoleCompletion"
      data-cell-id={@block.id}
      data-language={@block.language}
      data-node={@node}
    >
      <label
        id={"notebook-toggle-#{@block.id}"}
        phx-update="ignore"
        class="console-autocomplete-toggle small"
      ><input type="checkbox" checked /> Autocomplete</label>
      <div
        id={"notebook-editor-#{@block.id}"}
        class="module-source-editor"
        phx-hook="SourceEditor"
        data-language={@block.language}
        data-height-key="beamdash:notebook-source-height"
      >
        <pre id={"notebook-preview-#{@block.id}"} aria-hidden="true" phx-update="ignore"><code></code></pre>
        <textarea
          id={"notebook-source-#{@block.id}"}
          name="source"
          rows="8"
          wrap="off"
          aria-label={"#{@block.language} code cell"}
          aria-autocomplete="list"
          aria-controls={"notebook-options-#{@block.id}"}
          spellcheck="false"
          readonly={@busy}
          phx-debounce="200"
        >{@block.source}</textarea>
      </div>
      <div
        id={"notebook-options-#{@block.id}"}
        class="console-completions"
        role="listbox"
        aria-label="Module and function suggestions"
        phx-update="ignore"
        hidden
      >
      </div>
    </div>
    """
  end
end
