defmodule BeamdashWeb.ModulesLive do
  use Phoenix.LiveView

  alias Beamdash.{
    Console,
    Format,
    LocalSource,
    ModuleEditor,
    ModuleSource,
    Settings,
    SourceBrowser,
    Target
  }

  alias BeamdashWeb.FunctionList

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()
    if connected?(socket), do: Target.subscribe()
    {:ok, socket |> assign(status: status, node: node) |> reset() |> list_modules()}
  end

  defp reset(socket) do
    assign(socket,
      modules: [],
      module_filter: "",
      selected: nil,
      exported_functions: [],
      source: "",
      editor_revision: 0,
      original: nil,
      browser: nil,
      source_file_found: false,
      manual_source: nil,
      language: "erlang",
      project: "",
      compiled: nil,
      candidate_result: nil,
      candidate_function: "",
      candidate_arguments: "[]",
      backup: nil,
      deployed: nil,
      message: nil,
      function: "",
      arguments: "[]"
    )
  end

  defp list_modules(%{assigns: %{status: :connected, node: node}} = socket) do
    case Target.rpc(node, :code, :all_loaded, []) do
      {:ok, mods} -> assign(socket, modules: mods |> Enum.map(&elem(&1, 0)) |> Enum.sort())
      _ -> assign(socket, message: "Unable to list modules on the connected node.")
    end
  end

  defp list_modules(socket), do: socket

  @impl true
  def handle_event("filter_modules", %{"q" => query}, socket),
    do: {:noreply, assign(socket, module_filter: query)}

  def handle_event("refresh_modules", _, socket),
    do: {:noreply, list_modules(socket)}

  def handle_event("select", %{"module" => name}, socket) do
    mod = Enum.find(socket.assigns.modules, &(Atom.to_string(&1) == name))

    if mod && socket.assigns.backup == nil do
      default_language =
        if String.starts_with?(Atom.to_string(mod), "Elixir."), do: "elixir", else: "erlang"

      result = ModuleSource.get(socket.assigns.node, mod)

      source_file_found =
        match?({:ok, %{kind: kind, truncated: false}} when kind in [:file, :local], result)

      {source, language, project, message} =
        case result do
          {:ok, %{text: text, truncated: false} = result} ->
            language = if result.kind == :debug_info, do: "erlang", else: default_language

            origin =
              case result.kind do
                :debug_info -> "Reconstructed from BEAM debug information as Erlang"
                :local -> "Loaded local source"
                _ -> "Loaded source from the node"
              end

            project =
              if result.kind in [:local, :file],
                do: LocalSource.project_dir(result[:path]),
                else: nil

            {text, language, project || "",
             origin <> if(result[:path], do: ": #{result.path}", else: ".")}

          {:ok, %{truncated: true}} ->
            {"", default_language, "",
             "Source exceeds the 2 MiB limit and was truncated. It was not loaded into the editor to avoid compiling incomplete code. Paste a complete module to continue."}

          {:ok, %{kind: :none, reason: reason}} ->
            {"", default_language, "",
             "Source unavailable: " <>
               ModuleSource.reason(reason) <>
               ". Browse for a local source file, configure the application's local source folder in Settings, or paste its source here."}

          {:error, reason} ->
            {"", default_language, "", "Source retrieval failed: " <> Format.error(reason)}
        end

      {:noreply,
       assign(socket,
         selected: mod,
         exported_functions: exported_functions(socket.assigns.node, mod),
         browser: nil,
         source_file_found: source_file_found,
         manual_source: nil,
         editor_revision: socket.assigns.editor_revision + 1,
         source: source,
         original: %{source: source, language: language, project: project},
         language: language,
         project: project,
         compiled: nil,
         candidate_result: nil,
         message: message
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "browse_source_file",
        _,
        %{assigns: %{selected: mod, status: :connected}} = socket
      )
      when not is_nil(mod) do
    configured =
      Settings.source_dirs()
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))
      |> Enum.find(&File.dir?/1)

    path =
      cond do
        socket.assigns.project != "" and File.dir?(socket.assigns.project) ->
          socket.assigns.project

        configured != nil ->
          configured

        true ->
          System.user_home!()
      end

    {:noreply, assign(socket, browser: SourceBrowser.open(path))}
  end

  def handle_event(
        "source_browse_into",
        %{"name" => name},
        %{assigns: %{browser: browser}} = socket
      )
      when is_map(browser) do
    if name in browser.subdirs,
      do: {:noreply, assign(socket, browser: SourceBrowser.open(Path.join(browser.path, name)))},
      else: {:noreply, socket}
  end

  def handle_event("source_browse_up", _, %{assigns: %{browser: browser}} = socket)
      when is_map(browser),
      do: {:noreply, assign(socket, browser: SourceBrowser.open(Path.dirname(browser.path)))}

  def handle_event(
        "source_browse_path",
        %{"path" => path},
        %{assigns: %{browser: browser}} = socket
      )
      when is_map(browser),
      do: {:noreply, assign(socket, browser: SourceBrowser.open(path))}

  def handle_event("source_browse_close", _, socket),
    do: {:noreply, assign(socket, browser: nil)}

  def handle_event(
        "source_browse_pick",
        %{"name" => name},
        %{assigns: %{browser: browser, selected: mod, status: :connected}} = socket
      )
      when is_map(browser) and not is_nil(mod) do
    case SourceBrowser.load(browser, name) do
      {:ok, result} ->
        project = LocalSource.project_dir(result.path) || ""

        {:noreply,
         assign(socket,
           source: result.text,
           language: result.language,
           project: project,
           original: %{source: result.text, language: result.language, project: project},
           editor_revision: socket.assigns.editor_revision + 1,
           compiled: nil,
           candidate_result: nil,
           browser: nil,
           source_file_found: true,
           manual_source: result.path,
           message: "Loaded local source: #{result.path}"
         )}

      {:error, error} ->
        {:noreply, assign(socket, browser: %{browser | error: error})}
    end
  end

  def handle_event("clear_source", _, %{assigns: %{selected: selected}} = socket)
      when not is_nil(selected) do
    {:noreply,
     assign(socket,
       editor_revision: socket.assigns.editor_revision + 1,
       source: "",
       compiled: nil,
       candidate_result: nil,
       message: "Code cleared. Use Discard changes to restore the originally loaded source."
     )}
  end

  def handle_event("discard_source", _, %{assigns: %{original: original}} = socket)
      when is_map(original) do
    {:noreply,
     assign(socket,
       editor_revision: socket.assigns.editor_revision + 1,
       source: original.source,
       language: original.language,
       project: original.project,
       compiled: nil,
       candidate_result: nil,
       message: "Originally loaded source restored."
     )}
  end

  def handle_event(
        "edit",
        %{"source" => source, "language" => language, "project" => project},
        socket
      )
      when language in ["erlang", "elixir"],
      do:
        {:noreply,
         assign(socket,
           source: source,
           language: language,
           project: project,
           compiled: nil,
           candidate_result: nil
         )}

  def handle_event(
        "compile",
        %{"source" => source, "language" => language, "project" => project},
        %{assigns: %{selected: mod, node: node, status: :connected}} = socket
      )
      when not is_nil(mod) and language in ["erlang", "elixir"] do
    result =
      case Target.status() do
        %{status: :connected, node: ^node} ->
          if language == "elixir",
            do:
              ModuleEditor.compile_elixir(source, mod, node: node, project: String.trim(project)),
            else: ModuleEditor.compile(source)

        _ ->
          {:error, "The connection has changed."}
      end

    socket = assign(socket, language: language, project: project, candidate_result: nil)

    socket =
      case result do
        {:ok, mod, beam, warnings} when mod == socket.assigns.selected ->
          assign(socket,
            source: source,
            compiled: beam,
            message: "Compiled. Warnings: #{inspect(warnings)}"
          )

        {:ok, _, _, _} ->
          assign(socket,
            source: source,
            compiled: nil,
            message: "The source module must match the selected module."
          )

        {:error, error} ->
          assign(socket,
            source: source,
            compiled: nil,
            message: "Compilation failed: #{inspect(error)}"
          )
      end

    {:noreply, socket}
  end

  def handle_event(
        "test_candidate",
        %{"function" => function, "arguments" => arguments},
        %{assigns: %{compiled: beam, selected: mod, project: project, status: :connected}} =
          socket
      )
      when is_binary(beam) and is_atom(mod) and not is_nil(mod) do
    result =
      ModuleEditor.test_candidate(mod, beam, function, arguments, project: String.trim(project))

    message =
      case result do
        {:ok, value, ""} -> "Result: " <> value
        {:ok, value, log} -> "Result: " <> value <> "\nOutput:\n" <> log
        {:error, error} -> "Test failed: " <> error
      end

    {:noreply,
     assign(socket,
       candidate_function: function,
       candidate_arguments: arguments,
       candidate_result: message
     )}
  end

  def handle_event(
        "deploy",
        _,
        %{assigns: %{compiled: beam, selected: mod, node: node, backup: nil, status: :connected}} =
          socket
      )
      when is_binary(beam) and is_atom(mod) do
    with %{status: :connected, node: ^node} <- Target.status(),
         {:ok, backup} <- ModuleEditor.backup(node, mod),
         {:ok, {^mod, digest}} <- :beam_lib.md5(beam) do
      case ModuleEditor.load(node, mod, beam, backup.digest) do
        {:ok, ^digest} ->
          {:noreply,
           assign(socket,
             backup: backup,
             deployed: digest,
             compiled: nil,
             message: "Module deployed. Rollback is available while this page remains open."
           )}

        error ->
          {:noreply,
           assign(socket,
             backup: backup,
             deployed: digest,
             compiled: nil,
             message:
               "Deployment outcome may be uncertain: #{inspect(error)}. The backup is retained; rollback is available if the new code is running."
           )}
      end
    else
      error ->
        {:noreply, assign(socket, message: "Deployment failed before loading: #{inspect(error)}")}
    end
  end

  def handle_event(
        "rollback",
        _,
        %{
          assigns: %{
            backup: backup,
            deployed: digest,
            node: node,
            selected: mod,
            status: :connected
          }
        } = socket
      )
      when is_map(backup) do
    result =
      with %{status: :connected, node: ^node} <- Target.status(),
           do: ModuleEditor.load(node, mod, backup.beam, digest)

    case result do
      {:ok, _} ->
        {:noreply,
         assign(socket, backup: nil, deployed: nil, message: "Previous module restored.")}

      error ->
        {:noreply, assign(socket, message: "Rollback failed: #{inspect(error)}")}
    end
  end

  def handle_event(
        "test",
        %{"function" => fun, "arguments" => args},
        %{assigns: %{node: node, selected: mod, status: :connected}} = socket
      )
      when is_atom(mod) do
    result =
      with %{status: :connected, node: ^node} <- Target.status(),
           do: ModuleEditor.test_call(node, mod, fun, args)

    {:noreply,
     assign(socket,
       function: fun,
       arguments: args,
       message: "Test result: #{inspect(result, limit: 100, printable_limit: 2000)}"
     )}
  end

  def handle_event(
        "complete_editor",
        %{"token" => token, "language" => language},
        %{assigns: %{status: :connected, node: node, selected: selected}} = socket
      )
      when is_binary(token) and language in ["erlang", "elixir"] and not is_nil(selected) do
    items =
      if Target.status() == %{status: :connected, node: node},
        do: Console.complete(node, String.to_existing_atom(language), token),
        else: []

    {:reply, %{items: items}, socket}
  end

  def handle_event("complete_editor", _, socket), do: {:reply, %{items: []}, socket}
  def handle_event(_, _, socket), do: {:noreply, socket}

  defp exported_functions(node, mod) do
    case Target.rpc(node, mod, :module_info, [:exports], 1_000) do
      {:ok, exports} when is_list(exports) ->
        exports
        |> Enum.filter(fn {name, arity} ->
          is_atom(name) and is_integer(arity) and name not in [:module_info, :__info__]
        end)
        |> Enum.map(fn {name, arity} -> {Atom.to_string(name), arity} end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  @impl true
  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do: {:noreply, socket |> assign(status: :connected, node: node) |> reset() |> list_modules()}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, socket |> assign(status: :disconnected, node: nil) |> reset()}

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :shown_modules,
        FunctionList.matching_modules(
          Enum.map(assigns.modules, &{&1, [], []}),
          assigns.module_filter,
          assigns.syntax
        )
      )

    ~H"""
    <main class="wrap modules-page">
      <BeamdashWeb.Layouts.header
        active={:modules}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.show?(assigns[:jev_enabled])}
      />
      <h1>Modules</h1>
      <p :if={@status != :connected} class="help">Connect to a node to edit modules.</p>
      <section :if={@status == :connected}>
        <p class="warn">
          The source and the BEAM file on the server may differ from the running code. Local or reconstructed source may also differ. Deployment requires a BEAM file matching the running module.
        </p>
        <p class="warn">
          Pause other deployments and hot upgrades while deploying or rolling back. The running-code check and replacement are separate operations; a concurrent upgrade can be overwritten and make the backup stale.
        </p>
        <p class="help">
          Elixir compilation runs in a separate local VM matching the target's OTP and Elixir versions. A local Mix project can provide compiled dependencies and configuration; its Mix environment is used. Erlang compilation uses the dashboard's compiler. Compilation and project configuration can execute code on this machine.
        </p>
        <p class="help">
          Candidate tests run in a separate local VM, not a security sandbox: code can access local files and services. The live-node test calls the running module and can change node state. Rollback restores code only, not state; it is available only while this page remains open and connected.
        </p>
        <div class="trace-layout">
          <aside class="browser" aria-label="Loaded modules">
            <form phx-change="filter_modules" phx-submit="filter_modules" class="filter">
              <input
                id="module-search"
                type="search"
                name="q"
                value={@module_filter}
                placeholder="Filter modules"
                aria-label="Filter modules"
                phx-debounce="150"
                autocomplete="off"
              />
              <button
                type="button"
                class="secondary"
                phx-click="refresh_modules"
                title="Reload the module list"
              >↻</button>
            </form>
            <p class="muted small">
              {length(@shown_modules)} of {Format.number(length(@modules))} loaded modules
            </p>
            <p :if={length(@shown_modules) == 150} class="muted small">
              Showing up to 150 results. Refine the search to find more.
            </p>
            <p :if={@backup != nil} class="muted small">
              Roll back the deployed module before selecting another module.
            </p>
            <ul class="modules" aria-label="Matching modules">
              <li :for={mod <- @shown_modules} class={mod == @selected && "selected"}>
                <a
                  href="#"
                  phx-click={@backup == nil && "select"}
                  phx-value-module={mod}
                  aria-current={mod == @selected && "true"}
                  aria-disabled={to_string(@backup != nil)}
                  tabindex={if @backup != nil, do: "-1", else: "0"}
                  title={Format.name(mod, @syntax)}
                ><FunctionList.highlight
                  text={Format.name(mod, @syntax)}
                  needle={FunctionList.needle(@module_filter)}
                /></a>
              </li>
            </ul>
            <p :if={@shown_modules == []} class="muted small">No matching modules.</p>
          </aside>
          <section class="trace-main">
            <p :if={@selected == nil} class="help">Select a module to view or edit its source.</p>
            <h2 :if={@selected}>{Format.name(@selected, @syntax)}</h2>
            <pre :if={@message} role="status" style="white-space:pre-wrap">{@message}</pre>
            <div :if={@selected} class="module-workspace">
              <div :if={not @source_file_found or @manual_source != nil} class="module-source-actions">
                <button type="button" class="secondary module-action" phx-click="browse_source_file">
                  {if @manual_source, do: "Browse another file", else: "Browse local source"}
                </button>
              </div>
              <BeamdashWeb.SourceBrowser.picker :if={@browser} browser={@browser} />
              <form phx-change="edit" phx-submit="compile">
                <label>
                  Language
                  <select name="language">
                    <option value="erlang" selected={@language == "erlang"}>Erlang</option>
                    <option value="elixir" selected={@language == "elixir"}>Elixir</option>
                  </select>
                </label>
                <label>
                  Local Mix project directory (optional for Elixir)
                  <input name="project" value={@project} placeholder="/path/to/project" />
                </label>
                <div class="module-source-actions" role="group" aria-label="Editor actions">
                  <button
                    type="button"
                    class="secondary module-action"
                    phx-click="clear_source"
                    disabled={@source == ""}
                  >Clear code</button>
                  <button
                    type="button"
                    class="secondary module-action"
                    phx-click="discard_source"
                    disabled={
                      @original == nil or
                        (@source == @original.source and @language == @original.language and
                           @project == @original.project)
                    }
                    title="Restore the source, language and project loaded when this module was selected"
                  >Discard changes</button>
                </div>
                <BeamdashWeb.CodeEditor.editor
                  id={"module-source-#{@selected}"}
                  source={@source}
                  language={@language}
                  revision={@editor_revision}
                />
                <p class="muted small">
                  Ctrl/Cmd+Enter to compile · Ctrl/Cmd+F to search · Ctrl+Space for completion
                </p>
                <div class="module-actions" role="group" aria-label="Module actions">
                  <button type="submit" class="module-action" phx-disable-with="Compiling…">Compile</button>
                  <button
                    type="button"
                    class="module-action module-deploy"
                    phx-click="deploy"
                    phx-disable-with="Deploying…"
                    disabled={@compiled == nil or @backup != nil}
                    data-confirm={"Deploy #{@selected} to #{@node}? Pause other deployments and hot upgrades first; concurrent code changes can be overwritten."}
                  >Deploy</button>
                  <button
                    type="button"
                    class="module-action secondary"
                    phx-click="rollback"
                    phx-disable-with="Restoring…"
                    disabled={@backup == nil}
                    data-confirm={"Restore the previous #{@selected} module on #{@node}? Pause other deployments and hot upgrades first; concurrent code changes can be overwritten."}
                  >Rollback</button>
                  <span class="module-target muted small">Target: {@node}</span>
                </div>
              </form>
              <form :if={@compiled} phx-submit="test_candidate" class="module-test-panel">
                <h2>Test candidate before deployment (optional)</h2>
                <p class="help">
                  Runs the staged code locally with the selected Mix project, without deploying it. Local state and services may differ from the target.
                </p>
                <label>Exported function
                <input name="function" value={@candidate_function} required /></label>
                <label>Arguments (Erlang list)
                <input name="arguments" value={@candidate_arguments} required /></label>
                <button type="submit" class="secondary module-action" phx-disable-with="Testing…">Test candidate</button>
                <pre :if={@candidate_result} role="status" style="white-space:pre-wrap">{@candidate_result}</pre>
              </form>
              <form phx-submit="test" class="module-test-panel">
                <h2>Test running module</h2>
                <label>Exported function
                <input
                  name="function"
                  value={@function}
                  list="running-module-functions"
                  autocomplete="off"
                  required
                /></label>
                <datalist id="running-module-functions"><option
                  :for={{name, arity} <- @exported_functions}
                  value={name}
                  label={"#{name}/#{arity}"}
                >
                </option></datalist>
                <label>Arguments (Erlang list) <input name="arguments" value={@arguments} required /></label>
                <button type="submit" class="secondary module-action" phx-disable-with="Running…">Run on node</button>
              </form>
            </div>
          </section>
        </div>
      </section>
    </main>
    """
  end
end
