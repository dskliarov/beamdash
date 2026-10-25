defmodule Beamdash.Logs do
  @moduledoc """
  The target's log lines, from one source per connection.

  On connect, `Target.source/1` says where the connection came from:

    * a Direct connection gets a logger handler, `beamdash_logs`, added on
      the node with this process as its destination
      (`beamdash_agent:log_attach/1`); it sends batches of formatted events
      as `{beamdash_logs, entries, dropped}`. `Beamdash.Target` removes the
      handler again on disconnect.
    * a Kubernetes connection runs `kubectl logs -f --timestamps` on the
      pod through a Port; each line is parsed with `Beamdash.Logs.Parse`,
      indented lines are folded into the entry before them, and new entries
      go to subscribers at most every 100 ms.

  The last 2,000 entries are kept (newest first) across connections, as
  `Beamdash.Crashes` keeps its reports. A broken source never crashes this
  process: it shows as `status: {:ended, reason}`.

  Subscribers receive `{:beamdash_logs, {:entries, newest_first}}` (an
  entry already sent may come again, with the same id, after a
  continuation line was added to it), `{:beamdash_logs, :cleared}` and
  `{:beamdash_logs, {:info, info}}` whenever `info/1` changes.
  """

  use GenServer

  alias Beamdash.{Kubectl, Target}
  alias Beamdash.Logs.Parse

  @max_entries 2_000
  @flush_ms 100
  # kubectl output without a newline is joined up to this many bytes; the
  # rest of such a line is dropped
  @max_line 256 * 1024

  defstruct target: Target,
            source_fun: nil,
            logs_cmd: nil,
            node: nil,
            source: nil,
            kubectl: nil,
            status: :idle,
            level: nil,
            dropped: 0,
            entries: [],
            next_id: 1,
            subscribers: %{},
            port: nil,
            partial: [],
            partial_size: 0,
            pending: [],
            flush_armed: false,
            # id of the newest entry of the running kubectl stream, which
            # continuation lines are folded into
            fold_id: nil

  ## API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Entries, newest first (at most #{@max_entries})."
  def entries(server \\ __MODULE__), do: GenServer.call(server, :entries)

  @doc """
  `%{source: :direct | :kubectl | nil, status: :idle | :streaming |
  {:ended, term}, level: atom | nil, dropped: non_neg_integer, kubectl:
  map | nil}`; `kubectl` is the `{:kubectl, map}` payload of
  `Target.source/1`.
  """
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc "Restarts the current source (after its stream ended, say)."
  def reconnect(server \\ __MODULE__), do: GenServer.call(server, :reconnect, 15_000)

  @doc """
  The previous container's logs (`kubectl logs --previous`), newest first.
  Runs in the caller's process. `{:error, :not_kubectl}` for a Direct
  connection, `{:error, {exit_status, output}}` when kubectl fails.
  """
  def previous(server \\ __MODULE__) do
    with {:ok, {exe, args}} <- GenServer.call(server, :previous_cmd) do
      run_previous(exe, args)
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    # so a failing port never takes this process down, and terminate/2
    # gets to kill a running kubectl
    Process.flag(:trap_exit, true)
    target = Keyword.get(opts, :target, Target)
    :ok = Target.subscribe(target)

    state = %__MODULE__{
      target: target,
      source_fun: Keyword.get(opts, :source_fun, &Target.source/1),
      logs_cmd:
        Keyword.get(opts, :logs_cmd, fn args -> {System.find_executable("kubectl"), args} end)
    }

    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, state) do
    case Target.status(state.target) do
      %{status: :connected, node: node} ->
        {:noreply, changed(state, start(%{state | node: node}))}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:entries, _from, state),
    do: {:reply, Enum.take(state.entries, @max_entries), state}

  def handle_call(:info, _from, state), do: {:reply, info_of(state), state}

  def handle_call(:clear, _from, state) do
    notify(state, :cleared)
    {:reply, :ok, %{state | entries: [], pending: []}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  def handle_call(:reconnect, _from, %{node: nil} = state), do: {:reply, :ok, state}

  def handle_call(:reconnect, _from, state) do
    {:reply, :ok, changed(state, state |> stop() |> start())}
  end

  def handle_call(:previous_cmd, _from, state), do: {:reply, previous_cmd(state), state}

  @impl true
  def handle_info({:beamdash_target, {:connected, node}}, %{node: node, source: s} = state)
      when s != nil,
      do: {:noreply, state}

  def handle_info({:beamdash_target, {:connected, node}}, state) do
    new = state |> stop() |> Map.put(:node, node) |> start()
    {:noreply, changed(state, new)}
  end

  # A stream that has ended keeps saying so (and which pod it was): a pod
  # restart ends `kubectl logs` and then the port-forward, and "Stream
  # ended (exit N)" is the useful thing to show. The next :connected
  # starts afresh.
  def handle_info({:beamdash_target, {:disconnected, _}}, %{status: {:ended, _}} = state) do
    stopped = stop(state)

    new = %{
      stopped
      | node: nil,
        status: state.status,
        source: state.source,
        kubectl: state.kubectl
    }

    {:noreply, changed(state, new)}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, state) do
    {:noreply, changed(state, %{stop(state) | node: nil})}
  end

  # Direct: a batch from the node's collector, oldest first
  def handle_info({:beamdash_logs, list, dropped}, %{source: :direct} = state)
      when is_list(list) do
    {entries, next_id} =
      Enum.map_reduce(list, state.next_id, fn m, id ->
        {Map.put(from_agent(m), :id, id), id + 1}
      end)

    newest_first = Enum.reverse(entries)
    if newest_first != [], do: notify(state, {:entries, newest_first})

    new = %{
      state
      | entries: Enum.take(newest_first ++ state.entries, @max_entries),
        next_id: next_id,
        dropped: state.dropped + if(is_integer(dropped), do: dropped, else: 0)
    }

    {:noreply, changed(state, new)}
  end

  # kubectl: output of the current port
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state) do
    {:noreply, buffer_part(state, part)}
  end

  def handle_info({port, {:data, {:eol, part}}}, %{port: port} = state) do
    state = buffer_part(state, part)
    line = IO.iodata_to_binary(state.partial)
    {:noreply, add_line(%{state | partial: [], partial_size: 0}, line)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    new = state |> end_partial() |> flush() |> Map.merge(%{port: nil, status: {:ended, code}})
    {:noreply, changed(state, new)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when reason != :normal do
    new = state |> end_partial() |> flush() |> Map.merge(%{port: nil, status: {:ended, reason}})
    {:noreply, changed(state, new)}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_armed: false})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  # an old port's or collector's messages after a reconnect or disconnect,
  # a port's normal exit, ...
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  ## Sources

  defp start(state) do
    case safe(fn -> state.source_fun.(state.target) end) do
      {:ok, :direct} -> start_direct(state)
      {:ok, {:kubectl, %{} = k}} -> start_kubectl(%{state | source: :kubectl, kubectl: k})
      {:ok, _none} -> state
      {:error, reason} -> %{state | status: {:ended, reason}}
    end
  end

  defp start_direct(state) do
    state = %{state | source: :direct}

    case Target.rpc(state.node, :beamdash_agent, :log_attach, [self()]) do
      {:ok, {:ok, level}} -> %{state | status: :streaming, level: level}
      {:ok, other} -> %{state | status: {:ended, other}}
      {:error, reason} -> %{state | status: {:ended, reason}}
    end
  end

  defp start_kubectl(state) do
    result =
      safe(fn ->
        case kubectl_cmd(state, follow: true) do
          {:ok, {exe, args}} ->
            Port.open(
              {:spawn_executable, exe},
              [:binary, :exit_status, :stderr_to_stdout, {:line, 16_384}, args: args]
            )

          {:error, _} = error ->
            error
        end
      end)

    case result do
      {:ok, port} when is_port(port) -> %{state | port: port, status: :streaming}
      {:ok, {:error, reason}} -> %{state | status: {:ended, reason}}
      {:error, reason} -> %{state | status: {:ended, reason}}
    end
  end

  # Stops the running source (the node side of Direct is detached by
  # Target), keeping the entries.
  defp stop(state) do
    close_port(state.port)

    %{
      flush(state)
      | port: nil,
        fold_id: nil,
        partial: [],
        partial_size: 0,
        source: nil,
        kubectl: nil,
        status: :idle,
        level: nil
    }
  end

  defp kubectl_cmd(%{kubectl: k} = state, opts) do
    args = Kubectl.logs_args(k[:kubeconfig], k[:namespace], k[:pod], k[:container], opts)

    case state.logs_cmd.(args) do
      {nil, _args} -> {:error, :kubectl_not_found}
      {exe, args} -> {:ok, {exe, args}}
    end
  end

  defp previous_cmd(%{source: :kubectl} = state) do
    case safe(fn -> kubectl_cmd(state, previous: true) end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp previous_cmd(%{source: nil}), do: {:error, :not_connected}
  defp previous_cmd(_state), do: {:error, :not_kubectl}

  defp run_previous(exe, args) do
    case System.cmd(exe, args, stderr_to_stdout: true) do
      {output, 0} ->
        entries =
          output
          |> scrub()
          |> String.split("\n")
          |> drop_trailing_empty()
          |> Enum.reduce([], &fold_line/2)
          |> Enum.reverse()
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, id} -> Map.put(entry, :id, id) end)
          |> Enum.reverse()

        {:ok, entries}

      {output, status} ->
        {:error, {status, scrub(output)}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp drop_trailing_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  # newest first, as entries are kept
  defp fold_line(line, acc) do
    if Parse.blank?(line), do: acc, else: fold_nonblank(line, acc)
  end

  defp fold_nonblank(line, [newest | rest] = acc) do
    if Parse.continuation?(line),
      do: [append(newest, line) | rest],
      else: [Parse.line(line) | acc]
  end

  defp fold_nonblank(line, []), do: [Parse.line(line)]

  ## kubectl lines

  defp buffer_part(state, part) do
    room = @max_line - state.partial_size

    cond do
      room <= 0 ->
        state

      byte_size(part) <= room ->
        %{
          state
          | partial: [state.partial, part],
            partial_size: state.partial_size + byte_size(part)
        }

      true ->
        %{state | partial: [state.partial, binary_part(part, 0, room)], partial_size: @max_line}
    end
  end

  # a last line the process printed without a newline
  defp end_partial(%{partial_size: 0} = state), do: state

  defp end_partial(state) do
    line = IO.iodata_to_binary(state.partial)
    add_line(%{state | partial: [], partial_size: 0}, line)
  end

  defp add_line(state, line) do
    line = scrub(line)
    if Parse.blank?(line), do: state, else: add_nonblank(state, line)
  end

  defp add_nonblank(state, line) do
    case state.entries do
      [%{id: id} = newest | rest] when id == state.fold_id ->
        if Parse.continuation?(line) do
          updated = append(newest, line)
          # still pending: replace it there; already sent: send it again in
          # the next batch, with the same id
          pending =
            case state.pending do
              [%{id: ^id} | older] -> [updated | older]
              older -> [updated | older]
            end

          arm(%{state | entries: [updated | rest], pending: pending})
        else
          add_entry(state, Parse.line(line))
        end

      _ ->
        add_entry(state, Parse.line(line))
    end
  end

  defp add_entry(state, entry) do
    entry = Map.put(entry, :id, state.next_id)

    arm(%{
      state
      | entries: Enum.take([entry | state.entries], @max_entries),
        pending: Enum.take([entry | state.pending], @max_entries),
        next_id: state.next_id + 1,
        fold_id: state.next_id
    })
  end

  defp append(entry, line) do
    %{
      entry
      | message: entry.message <> "\n" <> Parse.line(line).message,
        raw: entry.raw <> "\n" <> line
    }
  end

  defp arm(%{flush_armed: false, pending: [_ | _]} = state) do
    Process.send_after(self(), :flush, @flush_ms)
    %{state | flush_armed: true}
  end

  defp arm(state), do: state

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    notify(state, {:entries, state.pending})
    %{state | pending: [], entries: Enum.take(state.entries, @max_entries)}
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", [Integer.to_string(os_pid)])
      nil -> :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end

  ## Direct entries

  defp from_agent(m) when is_map(m) do
    at = datetime(m[:at])
    level = m[:level]
    where = where(m[:mfa])
    message = scrub(m[:msg])

    raw =
      [DateTime.to_iso8601(at), "[#{level}]", where, message]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    %{
      at: at,
      level: level,
      pid: pid_text(m[:pid]),
      where: where,
      message: message,
      meta: meta(m[:meta]),
      raw: raw
    }
  end

  defp from_agent(other),
    do: from_agent(%{msg: inspect(other), at: nil, level: nil, pid: nil, mfa: nil, meta: []})

  defp datetime(us) when is_integer(us) do
    DateTime.from_unix!(us, :microsecond)
  rescue
    _ -> DateTime.utc_now()
  end

  defp datetime(_), do: DateTime.utc_now()

  defp pid_text(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  defp pid_text(_), do: nil

  defp where({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    module =
      case Atom.to_string(m) do
        "Elixir." <> alias -> alias
        name -> name
      end

    "#{module}:#{f}/#{a}"
  end

  defp where(_), do: nil

  defp meta(list) when is_list(list) do
    for {k, v} <- list, do: {scrub(k), scrub(v)}
  end

  defp meta(_), do: []

  # String.replace_invalid/1 needs Elixir 1.16; mix.exs allows 1.15
  defp scrub(text) when is_binary(text) do
    if String.valid?(text), do: text, else: scrub_invalid(text, [])
  end

  defp scrub(nil), do: ""
  defp scrub(other), do: scrub(inspect(other))

  defp scrub_invalid(bin, acc) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      {:error, good, <<_, rest::binary>>} ->
        scrub_invalid(rest, ["\uFFFD", good | acc])

      {:incomplete, good, _} ->
        IO.iodata_to_binary(Enum.reverse(["\uFFFD", good | acc]))

      done when is_binary(done) ->
        IO.iodata_to_binary(Enum.reverse([done | acc]))
    end
  end

  ## Helpers

  defp safe(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp info_of(state) do
    %{
      source: state.source,
      status: state.status,
      level: state.level,
      dropped: state.dropped,
      kubectl: state.kubectl
    }
  end

  # Tells subscribers about a change of info/1 between `old` and `new`.
  defp changed(old, new) do
    info = info_of(new)
    if info != info_of(old), do: notify(new, {:info, info})
    new
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:beamdash_logs, event}) end)
  end
end
