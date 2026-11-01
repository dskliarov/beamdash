defmodule BeamdashWeb.NotebookLive do
  use Phoenix.LiveView
  alias Beamdash.{Console, Format, Notebook, NotebookStore, Settings, Target}

  @impl true
  def mount(_, _, socket) do
    %{status: status, node: node} = Target.status()

    if connected?(socket) do
      Target.subscribe()
      Phoenix.PubSub.subscribe(Beamdash.PubSub, "settings")
    end

    {:ok,
     socket
     |> assign(
       status: status,
       node: node,
       cell_targets: %{},
       notebook: Notebook.new(),
       cell_targets: %{},
       filename: "untitled.livemd",
       saved_name: nil,
       version: :new,
       dirty: false,
       files: [],
       notebook_dir: Settings.notebooks_dir(),
       error: nil,
       notice: nil,
       sessions: %{},
       pending: nil,
       queue: [],
       results: %{},
       frame_updates: %{},
       chart_updates: %{},
       listener_output: "",
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
    case NotebookStore.list(socket.assigns.notebook_dir) do
      {:ok, files} -> assign(socket, files: files)
      {:error, reason} -> assign(socket, files: [], error: Format.error(reason))
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

  def handle_event("kino_text", %{"cell_id" => cell_id, "value" => value} = params, socket)
      when is_binary(value) and byte_size(value) <= 4096 do
    update_kino(socket, cell_id, Map.get(params, "widget_id"), value, [
      :text,
      :textarea,
      :password,
      :color,
      :url,
      :date,
      :checkbox,
      :number,
      :range,
      :select
    ])
  end

  def handle_event("kino_button", %{"cell_id" => cell_id} = params, socket),
    do: update_kino(socket, cell_id, Map.get(params, "widget_id"), "click", [:button])

  def handle_event("kino_layout_tab", %{"cell_id" => cell_id, "index" => index} = params, socket) do
    with {index, ""} <- Integer.parse(index),
         %{status: :ok, widget: widget} = result <- socket.assigns.results[cell_id],
         {:ok, updated} <- select_layout_tab(widget, Map.get(params, "layout_id"), index) do
      {:noreply,
       assign(socket,
         results: Map.put(socket.assigns.results, cell_id, %{result | widget: updated})
       )}
    else
      _ -> {:noreply, socket}
    end
  end

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

  def handle_event(
        "execution_target",
        %{"cell_id" => id, "target" => target},
        %{assigns: %{pending: nil}} = socket
      )
      when target in ["remote", "local"] do
    block = Enum.find(socket.assigns.notebook.blocks, &(&1.id == id and &1.executable))
    target = if target == "local", do: :local, else: :remote

    if block && target != cell_target(socket, id) do
      result = socket.assigns.results[id]
      if result, do: release_result(socket, result)

      results =
        if result,
          do: Map.put(socket.assigns.results, id, %{result | status: :stale}),
          else: socket.assigns.results

      {:noreply,
       assign(socket,
         notebook: Notebook.set_execution_target(socket.assigns.notebook, id, target),
         cell_targets: Map.put(socket.assigns.cell_targets, id, target),
         results: results,
         dirty: true,
         error: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("timeout", %{"timeout" => timeout}, socket)
      when timeout in ~w(5000 15000 30000 60000),
      do: {:noreply, assign(socket, timeout: String.to_integer(timeout))}

  def handle_event("open_notebook", %{"name" => name}, socket) do
    case NotebookStore.load(name, socket.assigns.notebook_dir) do
      {:ok, source, version} ->
        case Notebook.from_livemd(source) do
          {:ok, notebook} ->
            {:noreply,
             socket
             |> close_sessions()
             |> assign(
               notebook: notebook,
               cell_targets: saved_cell_targets(notebook),
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

    case NotebookStore.save(name, source, expected, socket.assigns.notebook_dir) do
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
        with {:ok, notebook} <- Notebook.from_livemd(source),
             {:ok, saved_name, version} <-
               NotebookStore.import(Path.basename(name), source, socket.assigns.notebook_dir) do
          {:noreply,
           socket
           |> close_sessions()
           |> assign(
             notebook: notebook,
             cell_targets: saved_cell_targets(notebook),
             filename: saved_name,
             saved_name: saved_name,
             version: version,
             dirty: false,
             results: %{},
             error: nil,
             notice: "Imported #{saved_name}. Review cells before running them."
           )
           |> list_files()
           |> push_event("notebook-replaced", %{})}
        else
          {:error, error} ->
            {:noreply, assign(socket, error: Format.error(error))}
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

  def handle_event("delete_cell", %{"id" => id}, %{assigns: %{pending: nil}} = socket) do
    release_widgets(socket)

    {:noreply,
     assign(socket,
       notebook: Notebook.remove(socket.assigns.notebook, id),
       cell_targets: Map.delete(socket.assigns.cell_targets, id),
       dirty: true,
       results: stale(socket.assigns.results)
     )}
  end

  def handle_event(
        "edit_cell",
        %{"cell_id" => id, "source" => source},
        %{assigns: %{pending: nil}} = socket
      ) do
    notebook = Notebook.update(socket.assigns.notebook, id, source, nil)
    if notebook != socket.assigns.notebook, do: release_widgets(socket)

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
        %{assigns: %{pending: nil}} = socket
      ) do
    block = Enum.find(socket.assigns.notebook.blocks, &(&1.id == id))

    items =
      if block && block.executable && current_target?(socket, cell_target(socket, id)),
        do:
          Console.complete(execution_node(socket, cell_target(socket, id)), block.language, token),
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

  def handle_event("reset_notebook_runtime", _, socket) do
    notebook = Notebook.clear_outputs(socket.assigns.notebook)

    dirty =
      socket.assigns.dirty or notebook != socket.assigns.notebook or
        (socket.assigns.include_outputs and map_size(socket.assigns.results) > 0)

    {:noreply,
     socket
     |> close_sessions()
     |> assign(
       notebook: notebook,
       results: %{},
       dirty: dirty,
       notice: "Notebook sessions reset and results cleared. Side effects are not undone."
     )}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp select_layout_tab(%{type: :layout, layout: :tabs, items: items} = layout, id, index)
       when (is_nil(id) or :erlang.map_get(:id, layout) == id) and index >= 0 and
              index < length(items),
       do: {:ok, Map.put(layout, :active, index)}

  defp select_layout_tab(%{items: items} = parent, id, index) do
    {items, found} =
      Enum.map_reduce(items, false, fn item, found ->
        case select_layout_tab(item, id, index) do
          {:ok, updated} -> {updated, true}
          :error -> {item, found}
        end
      end)

    if found, do: {:ok, %{parent | items: items}}, else: :error
  end

  defp select_layout_tab(_, _, _), do: :error

  defp update_kino(socket, cell_id, widget_id, value, allowed) do
    with %{status: :ok, widget: root} = result <- socket.assigns.results[cell_id],
         %{type: type, id: id} = widget <- find_kino_widget(root, widget_id),
         true <- type in allowed,
         true <- type != :checkbox or value in ["true", "false"],
         session when is_pid(session) <- result_session(socket, result),
         target <- Map.get(result, :execution_target, :remote),
         true <- current_target?(socket, target),
         {:ok, :ok} <- Console.set_input(execution_node(socket, target), session, id, value) do
      value = kino_value(type, value)

      updated =
        if type == :button,
          do: root,
          else: update_kino_widget(root, widget_id, Map.put(widget, :value, value))

      result = Map.put(result, :widget, updated)

      {:noreply,
       assign(socket, results: Map.put(socket.assigns.results, cell_id, result), error: nil)}
    else
      _ -> {:noreply, assign(socket, error: "Could not update the Kino input. Rerun its cell.")}
    end
  end

  defp find_kino_widget(root, nil), do: root

  defp find_kino_widget(%{type: type, items: items}, id) when type in [:frame, :layout],
    do:
      Enum.find_value(items, fn
        %{type: :interactive, widget: %{id: ^id} = widget} -> widget
        %{items: _} = child -> find_kino_widget(child, id)
        _ -> nil
      end)

  defp find_kino_widget(_, _), do: nil

  defp update_kino_widget(_root, nil, widget), do: widget

  defp update_kino_widget(%{type: type, items: items} = root, id, widget)
       when type in [:frame, :layout] do
    %{
      root
      | items:
          Enum.map(items, fn
            %{type: :interactive, widget: %{id: ^id}} = item -> %{item | widget: widget}
            %{items: _} = item -> update_kino_widget(item, id, widget)
            item -> item
          end)
    }
  end

  defp kino_value(:checkbox, value), do: value == "true"
  defp kino_value(:number, ""), do: nil
  defp kino_value(type, "") when type in [:url, :date], do: nil
  defp kino_value(:select, value), do: String.to_integer(value)

  defp kino_value(type, value) when type in [:number, :range] do
    case Integer.parse(value) do
      {number, ""} ->
        number

      _ ->
        {number, ""} = Float.parse(value)
        number
    end
  end

  defp kino_value(_, value), do: value

  defp result_session(socket, result),
    do: Map.get(result, :execution_session) || socket.assigns.sessions[{:remote, :elixir}]

  defp release_widgets(socket) do
    Enum.each(socket.assigns.results, fn {_id, result} -> release_result(socket, result) end)
  end

  defp release_result(socket, %{status: :ok, widget: %{id: id, type: type}} = result) do
    target = Map.get(result, :execution_target, :remote)
    session = result_session(socket, result)

    if is_pid(session) and current_target?(socket, target) do
      if type in [:frame, :layout],
        do: Console.release_frame(execution_node(socket, target), session, id),
        else: Console.release_input(execution_node(socket, target), session, id)
    end
  end

  defp release_result(_, _), do: :ok

  defp run_cell(socket, id) do
    block = Enum.find(socket.assigns.notebook.blocks, &(&1.id == id))
    target = cell_target(socket, id)

    cond do
      block == nil or not block.executable ->
        assign(socket, queue: [], error: "This block cannot be executed by the notebook runtime.")

      not current_target?(socket, target) ->
        assign(socket,
          queue: [],
          error: "Connect to a node before running this cell on the connected node."
        )

      byte_size(block.source) > 32768 ->
        assign(socket, queue: [], error: "Code cells must be at most 32 KiB to execute.")

      true ->
        if old = socket.assigns.results[id], do: release_result(socket, old)
        session_key = {target, block.language}
        node = execution_node(socket, target)

        session =
          case socket.assigns.sessions[session_key] do
            nil -> Console.start(node, self(), block.language)
            pid -> {:ok, pid}
          end

        case session do
          {:ok, pid} ->
            ref = make_ref()
            timeout = socket.assigns.timeout
            code = block.source

            socket
            |> assign(
              sessions: Map.put(socket.assigns.sessions, session_key, pid),
              pending: %{id: id, ref: ref, session: pid, target: target, node: node},
              frame_updates: %{},
              chart_updates: %{},
              error: nil,
              results:
                Map.put(socket.assigns.results, id, %{
                  status: :running,
                  output: "",
                  result: "",
                  execution_target: target,
                  execution_session: pid
                })
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

    pending = socket.assigns.pending

    response =
      response
      |> Map.put(:execution_target, Map.get(pending, :target, :remote))
      |> Map.put(
        :execution_session,
        Map.get(pending, :session) || socket.assigns.sessions[{:remote, :elixir}]
      )

    response = apply_pending_frame(response, socket.assigns.frame_updates)

    chart_updates =
      case response do
        %{widget: widget} ->
          Enum.flat_map(socket.assigns.chart_updates, fn {chart_id, events} ->
            if contains_chart?(widget, chart_id), do: events, else: []
          end)

        _ ->
          []
      end

    socket =
      assign(socket,
        pending: nil,
        chart_updates: %{},
        frame_updates: %{},
        results: Map.put(socket.assigns.results, id, response),
        dirty: socket.assigns.dirty or socket.assigns.include_outputs
      )

    socket =
      Enum.reduce(chart_updates, socket, fn event, acc ->
        push_event(acc, "kino-chart-update", Map.put(event, :cell_id, id))
      end)

    {:noreply,
     if(response.status == :ok,
       do: run_next(socket),
       else: assign(socket, queue: [], notice: "Execution stopped at the failed cell.")
     )}
  end

  def handle_async(_, _, socket), do: {:noreply, socket}

  defp apply_pending_frame(%{widget: widget} = response, updates) do
    widget =
      Enum.reduce(updates, widget, fn {id, {revision, items}}, current ->
        elem(update_frame_tree(current, id, revision, items), 0)
      end)

    %{response | widget: widget}
  end

  defp apply_pending_frame(response, _), do: response

  defp update_frame_tree(%{type: :frame, id: id} = frame, id, revision, items) do
    updated =
      if revision > Map.get(frame, :revision, 0),
        do: Map.merge(frame, %{items: items, revision: revision}),
        else: frame

    {updated, true}
  end

  defp update_frame_tree(%{items: children} = node, id, revision, items) do
    {children, found} =
      Enum.map_reduce(children, false, fn child, found ->
        {child, child_found} = update_frame_tree(child, id, revision, items)
        {child, found or child_found}
      end)

    {%{node | items: children}, found}
  end

  defp update_frame_tree(node, _, _, _), do: {node, false}

  @impl true
  def handle_info({:beamdash_kino_frame, session, frame_ref, revision, items}, socket)
      when is_integer(revision) and revision > 0 and is_list(items) do
    if session in Map.values(socket.assigns.sessions) do
      items = cap_frame_items(items)

      {results, _found} =
        Enum.map_reduce(socket.assigns.results, false, fn
          {id, %{status: :ok, widget: widget} = result}, found ->
            {widget, child_found} =
              if result_session(socket, result) == session,
                do: update_frame_tree(widget, frame_ref, revision, items),
                else: {widget, false}

            {{id, %{result | widget: widget}}, found or child_found}

          entry, found ->
            {entry, found}
        end)

      updates = socket.assigns.frame_updates

      updates =
        if socket.assigns.pending != nil and
             Map.get(
               socket.assigns.pending,
               :session,
               socket.assigns.sessions[{:remote, :elixir}]
             ) == session and
             (Map.has_key?(updates, frame_ref) or map_size(updates) < 8) and
             revision >
               (case updates[frame_ref] do
                  nil -> 0
                  {old, _} -> old
                end), do: Map.put(updates, frame_ref, {revision, items}), else: updates

      {:noreply, assign(socket, results: Map.new(results), frame_updates: updates)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:beamdash_kino_chart, session, chart_id, event, payload}, socket)
      when event in ["push", "set_param"] and is_binary(chart_id) and is_map(payload) do
    valid =
      case Jason.encode(payload) do
        {:ok, json} -> byte_size(json) <= 1_048_576
        _ -> false
      end

    active_cells =
      for {cell_id, %{status: :ok, widget: widget} = result} <- socket.assigns.results,
          result_session(socket, result) == session and contains_chart?(widget, chart_id),
          do: cell_id

    update = %{id: chart_id, event: event, payload: payload}

    cond do
      session not in Map.values(socket.assigns.sessions) or not valid ->
        {:noreply, socket}

      true ->
        socket =
          Enum.reduce(active_cells, socket, fn cell_id, acc ->
            push_event(acc, "kino-chart-update", Map.put(update, :cell_id, cell_id))
          end)

        if socket.assigns.pending != nil and
             Map.get(
               socket.assigns.pending,
               :session,
               socket.assigns.sessions[{:remote, :elixir}]
             ) == session do
          updates = socket.assigns.chart_updates
          current = Map.get(updates, chart_id, [])

          if length(current) < 100 and (Map.has_key?(updates, chart_id) or map_size(updates) < 8) do
            {:noreply,
             assign(socket, chart_updates: Map.put(updates, chart_id, current ++ [update]))}
          else
            {:noreply,
             assign(socket,
               error: "Kino chart updates exceeded the pending buffer; rerun the cell."
             )}
          end
        else
          {:noreply, socket}
        end
    end
  end

  def handle_info({:beamdash_console_output, session, output}, socket) when is_binary(output) do
    if session in Map.values(socket.assigns.sessions) do
      text = String.slice(socket.assigns.listener_output <> output, -16_000, 16_000)
      {:noreply, assign(socket, listener_output: text)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:beamdash_notebooks_dir, dir}, %{assigns: %{notebook_dir: dir}} = socket),
    do: {:noreply, socket}

  def handle_info({:beamdash_notebooks_dir, dir}, socket) do
    {:noreply,
     socket
     |> assign(
       notebook_dir: dir,
       saved_name: nil,
       version: :new,
       dirty: true,
       notice: "Notebook folder changed. Save the current notebook to keep it in the new folder."
     )
     |> list_files()}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do: {:noreply, socket |> close_remote_sessions() |> assign(status: :connected, node: node)}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, socket |> close_remote_sessions() |> assign(status: :disconnected, node: nil)}

  def handle_info(_, socket), do: {:noreply, socket}

  defp contains_chart?(%{type: :chart, id: id}, id), do: true
  defp contains_chart?(%{items: items}, id), do: Enum.any?(items, &contains_chart?(&1, id))
  defp contains_chart?(_, _), do: false

  defp cap_frame_items(items) do
    items
    |> Enum.take(-50)
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn item, {acc, size} ->
      bytes =
        case item do
          %{type: :interactive, widget: widget} ->
            byte_size(:erlang.term_to_binary(widget))

          %{type: type} when type in [:layout, :frame, :chart] ->
            byte_size(:erlang.term_to_binary(item))

          _ ->
            byte_size(Map.get(item, :text, Map.get(item, :data, "")))
        end

      if size + bytes <= 2_800_000,
        do: {:cont, {[item | acc], size + bytes}},
        else: {:halt, {acc, size}}
    end)
    |> elem(0)
  end

  defp saved_cell_targets(notebook) do
    Map.new(notebook.blocks, fn block -> {block.id, Notebook.execution_target(block)} end)
  end

  defp cell_target(socket, id), do: Map.get(socket.assigns.cell_targets, id, :remote)
  defp execution_node(_socket, :local), do: node()
  defp execution_node(socket, :remote), do: socket.assigns.node
  defp current_target?(_socket, :local), do: true

  defp current_target?(socket, :remote),
    do:
      socket.assigns.status == :connected and
        Target.status() == %{status: :connected, node: socket.assigns.node}

  defp close_remote_sessions(socket) do
    {remote, local} =
      Enum.split_with(socket.assigns.sessions, fn {{target, _}, _} -> target == :remote end)

    Enum.each(remote, fn {_, pid} -> Console.stop(pid) end)

    socket =
      if socket.assigns.pending && Map.get(socket.assigns.pending, :target, :remote) == :remote do
        socket
        |> cancel_async({:notebook_cell, socket.assigns.pending.ref})
        |> assign(pending: nil, queue: [], frame_updates: %{}, chart_updates: %{})
      else
        socket
      end

    results =
      Map.new(socket.assigns.results, fn {id, result} ->
        if Map.get(result, :execution_target, :remote) == :remote,
          do: {id, %{result | status: :stale}},
          else: {id, result}
      end)

    assign(socket, sessions: Map.new(local), results: results)
  end

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

    assign(socket,
      sessions: %{},
      pending: nil,
      queue: [],
      frame_updates: %{},
      chart_updates: %{},
      listener_output: ""
    )
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
        <p class="muted small notebook-folder" title={@notebook_dir}>{@notebook_dir}</p>
        <div class="notebook-list-heading">
          <span>Saved notebooks</span><span class="notebook-list-count">{length(@files)}</span>
        </div>
        <ul :if={@files != []} class="notebook-list" aria-label="Saved notebooks">
          <li :for={file <- @files}>
            <button
              type="button"
              class={[@saved_name == file && "active"]}
              aria-current={if @saved_name == file, do: "true"}
              title={file}
              phx-click="open_notebook"
              phx-value-name={file}
              data-notebook-confirm={@dirty && "Discard unsaved changes and open this notebook?"}
            ><span class="notebook-file-icon" aria-hidden="true">▤</span><span class="notebook-file-name">{Path.rootname(
              file,
              ".livemd"
            )}</span></button>
          </li>
        </ul>
        <p :if={@files == []} class="notebook-list-empty">
          No saved notebooks yet. Create or import one to get started.
        </p>
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
        <header class="notebook-header">
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
            <span class={["notebook-save-status", @dirty && "is-dirty"]} role="status">{if @dirty,
              do: "Unsaved changes",
              else: "Saved / unchanged"}</span>
            <button
              type="button"
              class="notebook-new-button"
              phx-click="new_notebook"
              data-notebook-confirm={@dirty && "Discard unsaved changes and create a notebook?"}
            >New notebook</button>
          </div>
          <form phx-change="include_outputs" class="notebook-output-option">
            <label class="small"><input
              type="checkbox"
              name="include_outputs"
              value="true"
              checked={@include_outputs}
            /> Include evaluated text output when saving/exporting</label>
          </form>
        </header>
        <div class="notebook-messages">
          <p :if={@error} class="notebook-message notebook-message-error" role="alert">{@error}</p>
          <p :if={@notice} class="notebook-message" role="status">{@notice}</p>
          <p :for={warning <- @notebook.warnings} class="notebook-message notebook-message-warning">
            {warning}
          </p>
          <div class="notebook-message notebook-runtime-info">
            <strong>Execution · Select a node for each code cell</strong>
            <p>
              Cells run with the selected node’s permissions and can change its live state. Opening or importing a notebook never runs code.
            </p>
            <p>
              Edits mark results stale. Run all starts fresh language sessions and stops at the first error; individual cells use the current session.
            </p>
          </div>
          <details class="notebook-compatibility">
            <summary>Livebook compatibility</summary>
            <p>
              LiveMarkdown (.livemd) source and metadata are preserved. Directly returned Kino text, textarea, password, color, URL, date, checkbox, number, range, select and button widgets support change and click subscriptions when Kino is running on the selected Elixir node. Kino frames and layouts support text, sanitized Markdown, PNG, JPEG and GIF images up to 1 MiB, and the supported controls. Direct Vega-Lite and Kino.VegaLite charts support inline data and live updates. Other JavaScript-powered widgets, file inputs, Smart cells, Python, attachments and branching runtimes require Livebook.
            </p>
          </details>
        </div>
        <div class="console-tools">
          <button
            type="button"
            phx-click="run_all"
            disabled={@pending != nil}
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
        <section :if={@listener_output != ""} class="notebook-listener-output" aria-live="polite">
          <h3>Live listener output</h3>
          <pre class="notebook-output">{@listener_output}</pre>
        </section>
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
              <div class="notebook-cell-actions">
                <form
                  :if={block.executable}
                  phx-change="execution_target"
                  class="notebook-cell-target"
                >
                  <input type="hidden" name="cell_id" value={block.id} />
                  <input type="hidden" name="target" value="remote" />
                  <label>
                    <input
                      type="checkbox"
                      name="target"
                      value="local"
                      checked={Map.get(@cell_targets, block.id, :remote) == :local}
                      disabled={@pending != nil}
                      aria-label={"Run #{block.language} cell on Beamdash node"}
                    /> Run on Beamdash
                  </label>
                </form>
                <button
                  :if={block.executable}
                  type="button"
                  phx-click="run_cell"
                  phx-value-id={block.id}
                  disabled={
                    (@cell_targets[block.id] != :local and @status != :connected) or @pending != nil
                  }
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
                  <.code_editor
                    block={block}
                    node={
                      if(Map.get(@cell_targets, block.id, :remote) == :local, do: node(), else: @node)
                    }
                    busy={@pending != nil}
                  />
                <% end %>
              </form>
            <% end %>
            <div :if={@results[block.id]} class="notebook-result" aria-live="polite">
              <span class="muted small">{@results[block.id].status}
              <%= if @results[block.id][:execution_target] do %>
                · {if @results[block.id].execution_target == :local,
                  do: "Beamdash node",
                  else: "Connected node"}
              <% end %></span>
              <pre :if={@results[block.id].output != ""} class="notebook-output">{@results[block.id].output}</pre>
              <%= if @results[block.id][:widget] && @results[block.id].status == :ok do %>
                <pre :if={@results[block.id].widget.type == :plain_text} class="notebook-output">{@results[block.id].widget.text}</pre>
                <div :if={@results[block.id].widget.type == :markdown} class="notebook-markdown">
                  {Phoenix.HTML.raw(Notebook.markdown_html(@results[block.id].widget.text))}
                </div>
                <.kino_chart
                  :if={@results[block.id].widget.type == :chart}
                  id={"kino-chart-#{block.id}"}
                  spec={@results[block.id].widget.spec}
                  chart_id={@results[block.id].widget[:id]}
                  cell_id={block.id}
                  datasets={@results[block.id].widget[:datasets] || []}
                />
                <img
                  :if={@results[block.id].widget.type == :image}
                  class="notebook-kino-image"
                  src={"data:#{@results[block.id].widget.mime};base64,#{@results[block.id].widget.data}"}
                  alt="Kino image output"
                />
                <div
                  :if={@results[block.id].widget.type == :frame}
                  class="notebook-kino-frame"
                  aria-live="polite"
                >
                  <p :if={@results[block.id].widget.items == []} class="muted small">
                    Frame is empty.
                  </p>
                  <.kino_item
                    :for={{item, index} <- Enum.with_index(@results[block.id].widget.items)}
                    item={item}
                    cell_id={block.id}
                    path={to_string(index)}
                  />
                </div>
                <div
                  :if={
                    @results[block.id].widget.type == :layout and
                      @results[block.id].widget.layout == :grid
                  }
                  class="notebook-kino-grid"
                  style={"--kino-columns: #{@results[block.id].widget.columns}"}
                >
                  <.kino_item
                    :for={{item, index} <- Enum.with_index(@results[block.id].widget.items)}
                    item={item}
                    cell_id={block.id}
                    path={to_string(index)}
                  />
                </div>
                <div
                  :if={
                    @results[block.id].widget.type == :layout and
                      @results[block.id].widget.layout == :tabs
                  }
                  class="notebook-kino-tabs"
                >
                  <div class="notebook-kino-tab-buttons" role="tablist" aria-label="Kino layout tabs">
                    <button
                      :for={{label, index} <- Enum.with_index(@results[block.id].widget.labels)}
                      type="button"
                      role="tab"
                      aria-selected={to_string(index == @results[block.id].widget.active)}
                      class={["secondary", index == @results[block.id].widget.active && "active"]}
                      phx-click="kino_layout_tab"
                      phx-value-cell_id={block.id}
                      phx-value-index={index}
                    >{label}</button>
                  </div>
                  <div
                    :for={{item, index} <- Enum.with_index(@results[block.id].widget.items)}
                    role="tabpanel"
                    hidden={index != @results[block.id].widget.active}
                  >
                    <.kino_item item={item} cell_id={block.id} path={to_string(index)} />
                  </div>
                </div>
                <button
                  :if={@results[block.id].widget.type == :button}
                  type="button"
                  phx-click="kino_button"
                  phx-value-cell_id={block.id}
                >{@results[block.id].widget.label}</button>
                <form
                  :if={
                    @results[block.id].widget.type not in [
                      :button,
                      :image,
                      :frame,
                      :layout,
                      :plain_text,
                      :markdown,
                      :chart
                    ]
                  }
                  phx-change="kino_text"
                  class="notebook-kino-input"
                >
                  <input type="hidden" name="cell_id" value={block.id} />
                  <label for={"kino-input-#{block.id}"}>{@results[block.id].widget.label}</label>
                  <input
                    :if={@results[block.id].widget.type in [:text, :password, :color, :url]}
                    id={"kino-input-#{block.id}"}
                    type={to_string(@results[block.id].widget.type)}
                    name="value"
                    value={@results[block.id].widget.value}
                    maxlength="4096"
                    phx-debounce="300"
                  />
                  <input
                    :if={@results[block.id].widget.type == :date}
                    id={"kino-input-#{block.id}"}
                    type="date"
                    name="value"
                    value={@results[block.id].widget.value}
                    min={@results[block.id].widget.min}
                    max={@results[block.id].widget.max}
                  />
                  <input
                    :if={@results[block.id].widget.type in [:number, :range]}
                    id={"kino-input-#{block.id}"}
                    type={to_string(@results[block.id].widget.type)}
                    name="value"
                    value={@results[block.id].widget.value}
                    min={@results[block.id].widget.min}
                    max={@results[block.id].widget.max}
                    step={@results[block.id].widget.step || "any"}
                    phx-debounce="300"
                  />
                  <select
                    :if={@results[block.id].widget.type == :select}
                    id={"kino-input-#{block.id}"}
                    name="value"
                  >
                    <option
                      :for={{index, label} <- @results[block.id].widget.options}
                      value={index}
                      selected={index == @results[block.id].widget.value}
                    >
                      {label}
                    </option>
                  </select>
                  <textarea
                    :if={@results[block.id].widget.type == :textarea}
                    id={"kino-input-#{block.id}"}
                    name="value"
                    maxlength="4096"
                    phx-debounce="300"
                  >{@results[block.id].widget.value}</textarea>
                  <input
                    :if={@results[block.id].widget.type == :checkbox}
                    type="hidden"
                    name="value"
                    value="false"
                  />
                  <input
                    :if={@results[block.id].widget.type == :checkbox}
                    id={"kino-input-#{block.id}"}
                    type="checkbox"
                    name="value"
                    value="true"
                    checked={@results[block.id].widget.value}
                  />
                </form>
              <% else %>
                <pre class={[@results[block.id].status == :error && "error", "notebook-output"]}>{@results[block.id].result}</pre>
              <% end %>
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

  attr :id, :string, required: true
  attr :spec, :map, required: true
  attr :chart_id, :string, default: nil
  attr :cell_id, :string, required: true
  attr :datasets, :list, default: []

  defp kino_chart(assigns) do
    assigns =
      assign(
        assigns,
        :encoded_spec,
        case Jason.encode(assigns.spec) do
          {:ok, json} when byte_size(json) <= 1_048_576 -> json
          _ -> nil
        end
      )

    assigns =
      assign(
        assigns,
        :encoded_datasets,
        case Jason.encode(assigns.datasets) do
          {:ok, json} when byte_size(json) <= 1_048_576 -> json
          _ -> "[]"
        end
      )

    ~H"""
    <div
      :if={@encoded_spec}
      id={@id}
      class="notebook-kino-chart"
      phx-hook="KinoChart"
      phx-update="ignore"
      data-spec={@encoded_spec}
      data-chart-id={@chart_id}
      data-cell-id={@cell_id}
      data-datasets={@encoded_datasets}
      role="img"
      aria-label="Vega-Lite chart"
    >
    </div>
    <p :if={is_nil(@encoded_spec)} class="error">
      Chart specification is too large or cannot be encoded.
    </p>
    """
  end

  attr :item, :map, required: true
  attr :cell_id, :string, required: true
  attr :path, :string, default: "0"

  defp kino_item(assigns) do
    ~H"""
    <div>
      <div
        :if={@item.type == :layout and @item.layout == :grid}
        class="notebook-kino-grid"
        style={"--kino-columns: #{@item.columns}"}
      >
        <.kino_item
          :for={{child, index} <- Enum.with_index(@item.items)}
          item={child}
          cell_id={@cell_id}
          path={"#{@path}-#{index}"}
        />
      </div>
      <div :if={@item.type == :layout and @item.layout == :tabs} class="notebook-kino-tabs">
        <div class="notebook-kino-tab-buttons" role="tablist" aria-label="Kino layout tabs">
          <button
            :for={{label, index} <- Enum.with_index(@item.labels)}
            type="button"
            role="tab"
            aria-selected={to_string(index == @item.active)}
            class={["secondary", index == @item.active && "active"]}
            phx-click="kino_layout_tab"
            phx-value-cell_id={@cell_id}
            phx-value-layout_id={@item.id}
            phx-value-index={index}
          >{label}</button>
        </div>
        <div
          :for={{child, index} <- Enum.with_index(@item.items)}
          role="tabpanel"
          hidden={index != @item.active}
        >
          <.kino_item item={child} cell_id={@cell_id} path={"#{@path}-#{index}"} />
        </div>
      </div>
      <div :if={@item.type == :frame} class="notebook-kino-frame" aria-live="polite">
        <p :if={@item.items == []} class="muted small">Frame is empty.</p>
        <.kino_item
          :for={{child, index} <- Enum.with_index(@item.items)}
          item={child}
          cell_id={@cell_id}
          path={"#{@path}-#{index}"}
        />
      </div>
      <.kino_chart
        :if={@item.type == :chart}
        id={"kino-chart-#{@cell_id}-#{@path}"}
        chart_id={@item[:id]}
        cell_id={@cell_id}
        spec={@item.spec}
        datasets={@item[:datasets] || []}
      />
      <pre :if={@item.type == :text} class="notebook-output">{@item.text}</pre>
      <div :if={@item.type == :markdown} class="notebook-markdown">
        {Phoenix.HTML.raw(Notebook.markdown_html(@item.text))}
      </div>
      <img
        :if={@item.type == :image}
        class="notebook-kino-image"
        src={"data:#{@item.mime};base64,#{@item.data}"}
        alt="Kino frame image"
      />
      <button
        :if={@item.type == :interactive and @item.widget.type == :button}
        type="button"
        phx-click="kino_button"
        phx-value-cell_id={@cell_id}
        phx-value-widget_id={@item.widget.id}
      >{@item.widget.label}</button>
      <form
        :if={@item.type == :interactive and @item.widget.type != :button}
        phx-change="kino_text"
        class="notebook-kino-input"
      >
        <input type="hidden" name="cell_id" value={@cell_id} />
        <input type="hidden" name="widget_id" value={@item.widget.id} />
        <label for={"kino-frame-#{@cell_id}-#{@path}-#{@item.widget.id}"}>{@item.widget.label}</label>
        <input
          :if={@item.widget.type in [:text, :password, :color, :url]}
          id={"kino-frame-#{@cell_id}-#{@path}-#{@item.widget.id}"}
          type={to_string(@item.widget.type)}
          name="value"
          value={@item.widget.value}
          maxlength="4096"
          phx-debounce="300"
        />
        <input
          :if={@item.widget.type == :date}
          id={"kino-frame-#{@cell_id}-#{@path}-#{@item.widget.id}"}
          type="date"
          name="value"
          value={@item.widget.value}
          min={@item.widget.min}
          max={@item.widget.max}
        />
        <input
          :if={@item.widget.type in [:number, :range]}
          id={"kino-frame-#{@cell_id}-#{@path}-#{@item.widget.id}"}
          type={to_string(@item.widget.type)}
          name="value"
          value={@item.widget.value}
          min={@item.widget.min}
          max={@item.widget.max}
          step={@item.widget.step || "any"}
          phx-debounce="300"
        />
        <select
          :if={@item.widget.type == :select}
          id={"kino-frame-#{@cell_id}-#{@path}-#{@item.widget.id}"}
          name="value"
        >
          <option
            :for={{index, label} <- @item.widget.options}
            value={index}
            selected={index == @item.widget.value}
          >
            {label}
          </option>
        </select>
        <textarea
          :if={@item.widget.type == :textarea}
          id={"kino-frame-#{@cell_id}-#{@path}-#{@item.widget.id}"}
          name="value"
          maxlength="4096"
          phx-debounce="300"
        >{@item.widget.value}</textarea>
        <input
          :if={@item.widget.type == :checkbox}
          type="hidden"
          name="value"
          value="false"
        />
        <input
          :if={@item.widget.type == :checkbox}
          id={"kino-frame-#{@cell_id}-#{@path}-#{@item.widget.id}"}
          type="checkbox"
          name="value"
          value="true"
          checked={@item.widget.value}
        />
      </form>
    </div>
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
