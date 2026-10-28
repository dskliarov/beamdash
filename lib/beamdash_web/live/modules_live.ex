defmodule BeamdashWeb.ModulesLive do
  use Phoenix.LiveView
  alias Beamdash.{ModuleEditor, ModuleSource, Target}

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()
    if connected?(socket), do: Target.subscribe()
    {:ok, socket |> assign(status: status, node: node) |> reset() |> list_modules()}
  end

  defp reset(socket) do
    assign(socket,
      modules: [],
      selected: nil,
      source: "",
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
  def handle_event("select", %{"module" => name}, socket) do
    mod = Enum.find(socket.assigns.modules, &(Atom.to_string(&1) == name))

    if mod && socket.assigns.backup == nil do
      {source, language} =
        case ModuleSource.get(socket.assigns.node, mod) do
          {:ok, %{text: text, truncated: false, kind: :debug_info}} ->
            {text, "erlang"}

          {:ok, %{text: text, truncated: false}} ->
            {text,
             if(String.starts_with?(Atom.to_string(mod), "Elixir."), do: "elixir", else: "erlang")}

          _ ->
            {"",
             if(String.starts_with?(Atom.to_string(mod), "Elixir."), do: "elixir", else: "erlang")}
        end

      {:noreply,
       assign(socket,
         selected: mod,
         source: source,
         language: language,
         compiled: nil,
         candidate_result: nil,
         message: nil
       )}
    else
      {:noreply, socket}
    end
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

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do: {:noreply, socket |> assign(status: :connected, node: node) |> reset() |> list_modules()}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, socket |> assign(status: :disconnected, node: nil) |> reset()}

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap">
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
        <p class="help">
          Elixir compilation runs in a separate local VM matching the target's OTP and Elixir versions. A local Mix project can provide compiled dependencies and configuration; its Mix environment is used. Erlang compilation uses the dashboard's compiler. Compilation and project configuration can execute code on this machine.
        </p>
        <p class="help">
          Candidate tests run in a separate local VM, not a security sandbox: code can access local files and services. The live-node test calls the running module and can change node state. Rollback restores code only, not state; it is available only while this page remains open and connected.
        </p>
        <form phx-change="select">
          <label>
            Loaded module
            <select name="module" disabled={@backup != nil}>
              <option value="">Select a module</option>
              <option :for={mod <- @modules} value={mod} selected={mod == @selected}>{mod}</option>
            </select>
          </label>
        </form>
        <div :if={@selected}>
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
            <label for="module-source">Source</label>
            <textarea
              id="module-source"
              name="source"
              rows="24"
              style="width:100%;font-family:monospace"
            >{@source}</textarea>
            <button type="submit">Compile</button>
          </form>
          <form :if={@compiled} phx-submit="test_candidate">
            <h2>Test candidate before deployment (optional)</h2>
            <p class="help">
              Runs the staged code locally with the selected Mix project, without deploying it. Local state and services may differ from the target.
            </p>
            <label>Exported function <input name="function" value={@candidate_function} required /></label>
            <label>Arguments (Erlang list)
            <input name="arguments" value={@candidate_arguments} required /></label>
            <button type="submit">Test candidate</button>
            <pre :if={@candidate_result} role="status" style="white-space:pre-wrap">{@candidate_result}</pre>
          </form>
          <button
            phx-click="deploy"
            disabled={@compiled == nil or @backup != nil}
            data-confirm={"Deploy #{@selected} to #{@node}?"}
          >Deploy to {@node}</button>
          <button
            phx-click="rollback"
            disabled={@backup == nil}
            data-confirm={"Restore the previous #{@selected} module on #{@node}?"}
          >Rollback</button>
          <form phx-submit="test">
            <label>Exported function <input name="function" value={@function} required /></label>
            <label>Arguments (Erlang list) <input name="arguments" value={@arguments} required /></label>
            <button type="submit">Run test on node</button>
          </form>
        </div>
        <pre :if={@message} role="status" style="white-space:pre-wrap">{@message}</pre>
      </section>
    </main>
    """
  end
end
