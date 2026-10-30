defmodule BeamdashWeb.ConsoleLive do
  use Phoenix.LiveView
  alias Beamdash.{Console, Format, Target}

  @impl true
  def mount(_, _, socket) do
    %{status: status, node: node} = Target.status()
    if connected?(socket), do: Target.subscribe()

    {:ok,
     assign(socket,
       status: status,
       node: node,
       view: :shell,
       language: socket.assigns[:syntax] || :erlang,
       session: nil,
       pending: nil,
       command: "",
       command_revision: 0,
       continuation: false,
       counter: 1,
       history: %{erlang: [], elixir: []},
       entries: [],
       error: nil
     )}
  end

  @impl true
  def handle_event("console_view", %{"view" => view}, socket) when view in ["shell", "notebook"],
    do: {:noreply, assign(socket, view: String.to_existing_atom(view))}

  def handle_event(
        "complete",
        %{"token" => token},
        %{assigns: %{status: :connected, node: node, pending: nil}} = socket
      ) do
    items =
      case Target.status() do
        %{status: :connected, node: ^node} ->
          Console.complete(node, socket.assigns.language, token)

        _ ->
          []
      end

    {:reply, %{items: items}, socket}
  end

  def handle_event("complete", _, socket), do: {:reply, %{items: []}, socket}

  def handle_event("command", %{"command" => code}, socket),
    do: {:noreply, assign(socket, command: code)}

  def handle_event("language", %{"language" => language}, socket)
      when language in ~w(erlang elixir) do
    {:noreply,
     socket
     |> close_session()
     |> assign(language: String.to_existing_atom(language), error: nil, command: "")
     |> replace_command()}
  end

  def handle_event(
        "execute",
        %{"command" => code},
        %{assigns: %{pending: nil, status: :connected, node: node}} = socket
      ) do
    code = String.trim(code)

    cond do
      code == "" ->
        {:noreply, socket}

      byte_size(code) > 32768 ->
        {:noreply, assign(socket, error: "Commands must be at most 32 KiB.")}

      Target.status() != %{status: :connected, node: node} ->
        {:noreply, assign(socket, error: "The node connection has changed.")}

      true ->
        result =
          if socket.assigns.session,
            do: {:ok, socket.assigns.session},
            else: Console.start(node, self(), socket.assigns.language)

        case result do
          {:ok, session} ->
            ref = make_ref()

            entry = %{
              id: ref,
              number: socket.assigns.counter,
              command: code,
              language: socket.assigns.language,
              status: :running,
              result: "",
              output: ""
            }

            {:noreply,
             socket
             |> assign(
               session: session,
               pending: ref,
               counter: socket.assigns.counter + 1,
               command: "",
               error: nil,
               entries: socket.assigns.entries ++ [entry]
             )
             |> replace_command()
             |> start_async({:evaluate, ref}, fn -> Console.submit(node, session, code) end)}

          {:error, reason} ->
            {:noreply, assign(socket, error: Format.error(reason))}
        end
    end
  end

  def handle_event("reset", _, socket),
    do:
      {:noreply,
       socket |> close_session() |> assign(error: nil, command: "") |> replace_command()}

  def handle_event("interrupt", _, socket) do
    socket = if socket.assigns.pending, do: close_session(socket), else: socket

    {:noreply,
     socket |> assign(command: "", continuation: false, error: nil) |> replace_command()}
  end

  def handle_event("clear", _, socket),
    do:
      {:noreply,
       assign(socket, entries: Enum.filter(socket.assigns.entries, &(&1.status == :running)))}

  def handle_event("reuse", %{"index" => index}, socket) do
    with {index, ""} <- Integer.parse(index),
         true <- index >= 0,
         entry when not is_nil(entry) <- Enum.at(socket.assigns.entries, index) do
      {:noreply, socket |> assign(command: entry.command) |> replace_command()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:evaluate, ref}, result, %{assigns: %{pending: ref}} = socket) do
    response =
      case result do
        {:ok, {:ok, response}} when is_map(response) -> response
        {:ok, {:error, reason}} -> %{status: :error, output: "", result: Format.error(reason)}
        {:exit, reason} -> %{status: :error, output: "", result: Format.error(reason)}
      end

    entry = Enum.find(socket.assigns.entries, &(&1.id == ref))

    if response.status == :incomplete and entry do
      {:noreply,
       socket
       |> assign(
         command: entry.command <> "\n",
         continuation: true,
         counter: entry.number,
         entries: Enum.reject(socket.assigns.entries, &(&1.id == ref)),
         pending: nil
       )
       |> replace_command()}
    else
      entries =
        Enum.map(socket.assigns.entries, fn entry ->
          if entry.id == ref, do: Map.merge(entry, response), else: entry
        end)

      history =
        if entry do
          Map.update!(socket.assigns.history, entry.language, fn commands ->
            if List.last(commands) == entry.command,
              do: commands,
              else: Enum.take(commands ++ [entry.command], -100)
          end)
        else
          socket.assigns.history
        end

      {:noreply,
       assign(socket,
         entries: Enum.take(entries, -50),
         pending: nil,
         continuation: false,
         history: history
       )}
    end
  end

  def handle_async(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do:
      {:noreply,
       socket
       |> close_session()
       |> assign(
         status: :connected,
         node: node,
         entries: [],
         command: "",
         error: nil,
         history: %{erlang: [], elixir: []}
       )
       |> replace_command()}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do:
      {:noreply,
       socket
       |> close_session()
       |> assign(
         status: :disconnected,
         node: nil,
         entries: [],
         command: "",
         error: nil,
         history: %{erlang: [], elixir: []}
       )
       |> replace_command()}

  def handle_info(_, socket), do: {:noreply, socket}

  defp close_session(socket) do
    socket =
      if socket.assigns.pending,
        do: cancel_async(socket, {:evaluate, socket.assigns.pending}),
        else: socket

    Console.stop(socket.assigns.session)

    entries =
      Enum.map(socket.assigns.entries, fn entry ->
        if entry.status == :running,
          do: %{entry | status: :error, result: "Session reset. Side effects are not undone."},
          else: entry
      end)

    assign(socket, session: nil, pending: nil, entries: entries, counter: 1, continuation: false)
  end

  defp replace_command(socket),
    do: assign(socket, command_revision: socket.assigns.command_revision + 1)

  defp prompt(:elixir, node, number), do: "iex(#{node})#{number}>"
  defp prompt(:erlang, node, number), do: "(#{node})#{number}>"

  @impl true
  def terminate(_, socket) do
    Console.stop(socket.assigns.session)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap console-page">
      <BeamdashWeb.Layouts.header
        active={:console}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.show?(assigns[:jev_enabled])}
      />
      <h1>Remote console</h1>
      <nav class="seg" aria-label="Console mode">
        <button
          :for={{view, label} <- [shell: "Shell", notebook: "Notebooks"]}
          type="button"
          class={["seg-btn", @view == view && "active"]}
          phx-click="console_view"
          phx-value-view={view}
        >{label}</button>
      </nav>
      <p :if={@view == :shell and @status != :connected} class="help">
        Connect to a node to open its console.
      </p>
      <section
        :if={@view == :shell and @status == :connected}
        id="console-repl"
        phx-hook="ReplConsole"
        data-busy={to_string(@pending != nil)}
        data-command-revision={@command_revision}
        data-command={@command}
        data-history={Jason.encode!(@history[@language])}
      >
        <p class="notice">
          Commands execute on <strong class="mono">{@node}</strong>
          and can modify live application state. A timeout stops the evaluator after 5 seconds and resets bindings; side effects and spawned processes can remain.
        </p>
        <div class="console-tools">
          <form phx-change="language">
            <label>Language
            <select name="language" disabled={@pending != nil}>
              <option value="erlang" selected={@language == :erlang}>Erlang</option>
              <option value="elixir" selected={@language == :elixir}>Elixir</option>
            </select></label>
          </form>
          <button type="button" class="secondary" phx-click="clear">Clear transcript</button>
          <button type="button" class="secondary" phx-click="reset">Reset session</button>
          <button :if={@pending} type="button" class="secondary" phx-click="interrupt">Interrupt (Ctrl+C)</button>
        </div>
        <p class="help small">
          Enter runs a command; Shift+Enter adds a line. ↑/↓ recalls history at the first/last line. Ctrl+C interrupts; Ctrl+L clears the transcript. Bindings persist until reset, timeout or language change. Elixir mode requires Elixir on the target.
        </p>
        <div class="console-terminal">
          <div
            class="console-transcript"
            role="log"
            aria-label="Console transcript"
            aria-live="polite"
          >
            <p :if={@entries == []} class="muted">Enter an expression below to begin.</p>
            <article :for={{entry, index} <- Enum.with_index(@entries)} class="console-entry">
              <div class="console-entry-head">
                <span class="muted small">{entry.language}</span><button
                  type="button"
                  class="secondary small-btn"
                  phx-click="reuse"
                  phx-value-index={index}
                >Reuse</button>
              </div>
              <pre class="console-command"><span class="repl-prompt">{prompt(entry.language, @node, Map.get(entry, :number, index + 1))}</span> {entry.command}</pre>
              <pre :if={entry.output != ""} class="console-output">{entry.output}</pre>
              <pre :if={entry.status == :ok} class="console-result"><code
                id={"console-result-#{Base.url_encode64(:erlang.term_to_binary(entry.id), padding: false)}"}
                class={"language-#{entry.language}"}
                phx-hook="Highlight"
                phx-update="ignore"
              >{entry.result}</code></pre>
              <pre :if={entry.status != :ok} class={entry.status == :error && "error"}>{if entry.status == :running, do: "Running…", else: entry.result}</pre>
            </article>
          </div>
          <form phx-change="command" phx-submit="execute" class="console-input">
            <div
              id="console-completion"
              phx-hook="ConsoleCompletion"
              data-language={@language}
              data-node={@node}
            >
              <div class="console-completion-tools">
                <label for="console-command">Shell input</label>
                <label
                  id="console-autocomplete-toggle"
                  phx-update="ignore"
                  class="console-autocomplete-toggle"
                ><input type="checkbox" checked /> Autocomplete</label>
              </div>
              <div class="repl-input-row">
                <span class="repl-prompt" aria-hidden="true">{if @continuation,
                  do: "...>",
                  else: prompt(@language, @node, @counter)}</span>
                <textarea
                  id="console-command"
                  name="command"
                  rows="1"
                  spellcheck="false"
                  autocomplete="off"
                  aria-autocomplete="list"
                  aria-controls="console-completions"
                  aria-expanded="false"
                  placeholder={if @language == :elixir, do: "Node.self()", else: "node()."}
                  readonly={@pending != nil}
                  aria-label="Shell expression"
                >{@command}</textarea>
              </div>
              <div
                id="console-completions"
                class="console-completions"
                role="listbox"
                aria-label="Module and function suggestions"
                phx-update="ignore"
                hidden
              >
              </div>
              <p class="muted small">
                {if @language == :erlang,
                  do: "End Erlang commands with a period. ",
                  else: "Incomplete expressions continue on the next line. "}Autocomplete: Tab/Enter inserts a suggestion · Escape dismisses · Ctrl+Space opens
              </p>
            </div>
            <div class="console-tools">
              <button type="submit" disabled={@pending != nil}>{if @pending,
                do: "Running…",
                else: "Run command"}</button><span class="muted small">Last 50 commands · ↑/↓ history keeps 100 commands per language · output limited to 64 KB per command</span>
            </div>
          </form>
        </div>
        <p :if={@error} class="error" role="alert">{@error}</p>
      </section>
      <div hidden={@view != :notebook}>
        <%= if connected?(@socket) do %>
          {live_render(@socket, BeamdashWeb.NotebookLive, id: "console-notebooks", session: %{})}
        <% else %>
          <p class="muted">Loading notebooks…</p>
        <% end %>
      </div>
    </main>
    """
  end
end
