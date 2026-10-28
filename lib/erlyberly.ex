# erlyberly, erlang trace debugger
# Copyright (C) 2016 Andy Till
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

defmodule :erlyberly do
  @moduledoc """
  erlyberly's agent, ported from `erlyberly.erl` to Elixir.

  This module is loaded into the node being inspected, and that node may be
  a pure Erlang node with no Elixir installed. So the code below may only
  call Erlang/OTP modules: no `Enum`, `String`, `Keyword`, `Map`, string
  interpolation, `inspect`, `raise`/`rescue` or comprehensions. Lists are
  charlists (`~c"..."`), errors are raised with `:erlang.error/1` and caught
  with `catch kind, reason`. `Beamdash.AgentTest` checks the compiled BEAM
  imports nothing from Elixir.

  The module keeps its Erlang name, `erlyberly`, and the same functions and
  return values as the Erlang original, so the beamdash side is unchanged.

  Tracing calls the trace BIFs (`erlang:trace/3`, `erlang:trace_pattern/3`)
  directly instead of `dbg`, which is in `runtime_tools`: releases often
  leave that application out. As with `dbg`, a small tracer process
  (`erlyberly_tracer`) receives the trace messages and passes them to the
  collector.
  """

  @behaviour :gen_event

  # These run on the target node, which has the tools (xref) and
  # syntax_tools applications; beamdash itself does not need them.
  @compile {:no_warn_undefined, [:xref, :erl_syntax, :erl_prettypr]}

  @tcollector :erlyberly_tcollector
  @tracer :erlyberly_tracer
  @seq_tracer :erlyberly_seq_trace
  @xref :erlyberly_xref

  ## ===========================================================================
  ## process info
  ## ===========================================================================

  @doc """
  Asynchronously load all modules on the path where the app directory
  matches the given regular expression.
  """
  def load_modules_on_path(regex_validator) do
    :proc_lib.spawn(fn -> load_modules_on_path2(regex_validator) end)
  end

  defp load_modules_on_path2(regex_validator) do
    paths = :lists.filter(&(:re.run(&1, regex_validator) != :nomatch), :code.get_path())

    :lists.foreach(
      fn path ->
        :lists.foreach(
          &:code.ensure_loaded(file_name_to_module(&1)),
          :filelib.wildcard(path ++ ~c"/*.beam")
        )
      end,
      paths
    )
  end

  defp file_name_to_module(filename) do
    :erlang.list_to_atom(:filename.rootname(:filename.basename(filename)))
  end

  def process_info do
    process_info2(:erlang.processes(), [])
  end

  defp process_info2([], acc), do: acc
  defp process_info2([:undefined | tail], acc), do: process_info2(tail, acc)

  defp process_info2([proc | tail], acc) do
    keys = [
      :registered_name,
      :reductions,
      :message_queue_len,
      :heap_size,
      :stack_size,
      :total_heap_size
    ]

    acc1 =
      case :erlang.process_info(proc, keys) do
        :undefined ->
          acc

        props ->
          props1 = add_global_name(proc, props)
          [[{:pid, :erlang.pid_to_list(proc)} | size_props_to_bytes(props1)] | acc]
      end

    process_info2(tail, acc1)
  end

  defp add_global_name(proc, props) do
    case find_global_name(proc) do
      :not_found -> props
      name -> [{:global_name, name} | props]
    end
  end

  defp find_global_name(pid) do
    names = :lists.filter(&(:global.whereis_name(&1) === pid), :global.registered_names())

    case names do
      [] -> :not_found
      [name] -> name
    end
  end

  defp size_props_to_bytes(props), do: :lists.map(&size_to_bytes/1, props)

  defp size_to_bytes({k, size}) when k in [:heap_size, :stack_size, :total_heap_size],
    do: {k, size * :erlang.system_info(:wordsize)}

  defp size_to_bytes(kv), do: kv

  def get_process_state(pid_string) when is_list(pid_string) do
    pid = :erlang.list_to_pid(pid_string)
    state = :sys.get_state(pid, 3000)

    case :proc_lib.initial_call(pid) do
      {mod, _, _} -> {:ok, format_record(state, mod)}
      false -> {:ok, state}
    end
  end

  defp format_record(rec, mod) when is_list(rec) do
    :lists.map(&format_record(&1, mod), rec)
  end

  defp format_record(rec, mod) when is_atom(elem(rec, 0)) do
    try do
      {:ok, forms} = load_module_forms(mod)
      [name | rec_values] = :erlang.tuple_to_list(rec)

      [field_names] =
        :lists.filtermap(
          fn
            {:attribute, _, :record, {^name, fields}} -> {true, record_fields(fields)}
            _ -> false
          end,
          forms
        )

      fields_as_tuples =
        :lists.zipwith(
          fn k, v -> {:erlyberly_record_field, k, v} end,
          field_names,
          :lists.map(&format_record(&1, mod), rec_values)
        )

      {:erlyberly_record, name, fields_as_tuples}
    catch
      # The module might not contain abstract_code (compiled without
      # debug_info) or we are treating a normal tuple as a record.
      _, _ -> rec
    end
  end

  defp format_record(other, _mod), do: other

  defp record_fields([{:record_field, _, {:atom, _, field}} | fs]),
    do: [field | record_fields(fs)]

  defp record_fields([{:record_field, _, {:atom, _, field}, _} | fs]),
    do: [field | record_fields(fs)]

  defp record_fields([{:typed_record_field, {:record_field, _, {:atom, _, field}}, _} | fs]),
    do: [field | record_fields(fs)]

  defp record_fields([{:typed_record_field, {:record_field, _, {:atom, _, field}, _}, _} | fs]),
    do: [field | record_fields(fs)]

  defp record_fields([]), do: []

  defp load_module_forms(mod) do
    beam_path = :code.which(mod)

    case :beam_lib.chunks(beam_path, [:abstract_code]) do
      {:ok, {_mod, [{:abstract_code, {_version, forms}}]}} ->
        {:ok, forms}

      # no beam file or no abstract code, try the source
      error ->
        compile_info = mod.module_info(:compile)
        options = :proplists.get_value(:options, compile_info, [])

        case :proplists.get_value(:source, compile_info) do
          :undefined ->
            error

          src_path ->
            includes =
              for_each_option(options, fn
                {:i, path} -> {true, path}
                _ -> false
              end)

            macros =
              for_each_option(options, fn
                {:d, macro} -> {true, macro}
                {:d, macro, value} -> {true, {macro, value}}
                _ -> false
              end)

            :epp.parse_file(src_path, includes, macros)
        end
    end
  end

  defp for_each_option(options, fun), do: :lists.filtermap(fun, options)

  @doc """
  The records of a module.

      (derp@mac)4> erlyberly:load_module_records(gen_event).
      {ok,[{handler,[module,id,state,supervised]}]}
  """
  def load_module_records(mod) do
    {:ok, forms} = load_module_forms(mod)

    records =
      :lists.filtermap(
        fn
          {:attribute, _, :record, {tag, fields}} -> {true, {tag, record_fields(fields)}}
          _ -> false
        end,
        forms
      )

    {:ok, records}
  end

  ## ===========================================================================
  ## module function tree
  ## ===========================================================================

  def module_functions do
    :lists.sort(:lists.map(fn {mod, _path} -> module_functions2(mod) end, :code.all_loaded()))
  end

  defp module_functions2(mod) when is_atom(mod) do
    exports = mod.module_info(:exports)
    unexported = :lists.filter(&(not :lists.member(&1, exports)), mod.module_info(:functions))
    {mod, exports, unexported}
  end

  ## ===========================================================================
  ## tracing
  ## ===========================================================================

  def start_trace({node, pid}, mod, func, arity, max_queue_len)
      when is_atom(node) and is_pid(pid) and is_integer(max_queue_len) do
    ensure_tracer_started({node, pid}, max_queue_len)
    ref = make_ref()
    send(@tcollector, {:start_trace, mod, func, arity, self(), ref})

    receive do
      {:ok, ^ref} -> {:ok, :erlang.whereis(@tcollector)}
      error when elem(error, 0) == :error -> error
    after
      1000 -> {:error, :timeout}
    end
  end

  def stop_trace(mod, func, arity, _is_exported) do
    # Clear the pattern here, synchronously, so no call made after this
    # returns is traced; the collector then drops it from its list.
    clear_pattern({mod, func, arity}, :local)
    send(@tcollector, {:stop_trace, mod, func, arity})
    :ok
  end

  def stop_traces do
    send(@tcollector, :stop_traces)
    :ok
  end

  defp when_process_is_unregistered(proc_name, fun) do
    case :erlang.whereis(proc_name) do
      :undefined -> fun.()
      _ -> :ok
    end
  end

  def ensure_tracer_started({eb_node, eb_pid}, max_queue_len) do
    when_process_is_unregistered(@tracer, fn ->
      :erlang.register(@tracer, :proc_lib.spawn(__MODULE__, :erlyberly_tracer, []))
    end)

    when_process_is_unregistered(@tcollector, fn ->
      pid = :proc_lib.spawn(__MODULE__, :erlyberly_tcollector, [eb_node, eb_pid, max_queue_len])
      :erlang.register(@tcollector, pid)
    end)
  end

  @doc false
  # The tracer: passes every trace message to the collector (dropped while
  # there is none, as for a seq trace's own call patterns).
  def erlyberly_tracer do
    receive do
      trace ->
        case :erlang.whereis(@tcollector) do
          :undefined -> :ok
          collector -> send(collector, trace)
        end

        erlyberly_tracer()
    end
  end

  # Call tracing (with timestamps) for every process, sent to the tracer;
  # dbg:p(all, [c, timestamp]). The tracer and the collector are left out,
  # so their own calls never feed back into the trace.
  defp trace_calls do
    case :erlang.whereis(@tracer) do
      :undefined ->
        {:error, :no_tracer}

      tracer ->
        n = :erlang.trace(:all, true, [:call, :timestamp, {:tracer, tracer}])

        :lists.foreach(
          fn name ->
            case :erlang.whereis(name) do
              :undefined -> :ok
              pid -> catch_trace_off(pid)
            end
          end,
          [@tracer, @tcollector]
        )

        {:ok, n}
    end
  end

  defp catch_trace_off(pid) do
    try do
      :erlang.trace(pid, false, [:all])
    catch
      _, _ -> :ok
    end
  end

  # dbg:tp (global: exported functions) and dbg:tpl (local: all functions)
  defp set_pattern(mfa, match_spec, scope), do: :erlang.trace_pattern(mfa, match_spec, [scope])
  defp clear_pattern(mfa, scope), do: :erlang.trace_pattern(mfa, false, [scope])

  # Stop tracing: clear every trace flag and pattern and stop the tracer,
  # as dbg:stop/0 does (dbg:stop_clear/0 before OTP 26).
  defp stop_clear do
    _ = :erlang.trace(:all, false, [:all])
    _ = clear_pattern({:_, :_, :_}, :local)
    _ = clear_pattern({:_, :_, :_}, :global)

    case :erlang.whereis(@tracer) do
      :undefined ->
        :ok

      pid ->
        catch_unregister(@tracer)
        :erlang.exit(pid, :kill)
        :ok
    end
  end

  defp catch_unregister(name) do
    try do
      :erlang.unregister(name)
    catch
      _, _ -> :ok
    end
  end

  # Collector state: ui_pid receives the logs; traces are the {M, F, A}
  # being traced; tracing is suspended when the collector's message queue
  # grows past max_queue_len.
  def erlyberly_tcollector(node, pid, max_queue_len) when is_integer(max_queue_len) do
    # throws a badarg if the node has already closed down
    :erlang.monitor_node(node, true)

    # Trace the returns of the code module to hear about code reloads: a
    # reload removes all traces on that module, so they are re-applied.
    {:ok, _} = trace_calls()
    # it may not be registered yet, so trace_calls/0 could not leave it out
    catch_trace_off(self())
    _ = set_pattern({:code, :_, :_}, [{:_, [], [{:exception_trace}]}], :global)
    tcollector2(%{ui_pid: pid, traces: [], max_queue_len: max_queue_len})
  end

  defp tcollector2(%{ui_pid: ui_pid, max_queue_len: max_queue_len} = tc) do
    case :erlang.process_info(self(), :message_queue_len) do
      {:message_queue_len, queue_len} when queue_len > max_queue_len ->
        :ok = stop_clear()
        send(ui_pid, {:erlyberly_trace_overload, queue_len})
        collect_overloading_logs(max_queue_len, tc)

      _ ->
        receive_next_trace(tc)
    end
  end

  # Collect logs still in the message queue after tracing was suspended,
  # to show what caused the overload.
  defp collect_overloading_logs(0, _), do: :ok

  defp collect_overloading_logs(max_queue_len, tc) do
    receive do
      log ->
        case collect_log(log) do
          :skip -> :ok
          {:erlyberly_module_loaded, _} -> :ok
          trace_log -> notify_trace_log(trace_log, tc)
        end

        collect_overloading_logs(max_queue_len - 1, tc)
    after
      0 -> :ok
    end
  end

  defp receive_next_trace(%{traces: traces} = tc) do
    receive do
      {:start_trace, mod, func, arity, requester, ref}
      when is_pid(requester) and is_reference(ref) ->
        tc1 = tcollector_start_trace(mod, func, arity, tc)
        send(requester, {:ok, ref})
        tcollector2(tc1)

      {:stop_trace, mod, func, arity} ->
        clear_pattern({mod, func, arity}, :local)
        tcollector2(%{tc | traces: traces -- [{mod, func, arity}]})

      :stop_traces ->
        :ok = stop_clear()

      {:nodedown, _node} ->
        :ok = stop_clear()

      log ->
        case collect_log(log) do
          :skip ->
            :ok

          {:erlyberly_module_loaded, loaded_module} ->
            :ok = reapply_traces(loaded_module, traces)
            :ok = notify_module_loaded(loaded_module, tc)

          trace_log ->
            notify_trace_log(trace_log, tc)
        end

        tcollector2(tc)
    end
  end

  defp tcollector_start_trace(mod, func, arity, %{traces: traces} = tc) do
    trace_spec = {mod, func, arity}
    _ = set_pattern(trace_spec, trace_match_spec(), :local)
    _ = trace_calls()
    %{tc | traces: [trace_spec | traces]}
  end

  # ensure_loaded can be called many times for one reload, so skip it
  defp collect_log({:trace_ts, _, :return_from, {:code, :ensure_loaded, _}, _}), do: :skip

  # a module was (re)loaded: its traces must be re-applied
  defp collect_log({:trace_ts, _, :return_from, {:code, _, _}, {:module, loaded_module}, _}),
    do: {:erlyberly_module_loaded, loaded_module}

  defp collect_log({:trace_ts, _, _, {:code, _, _}, _}), do: :skip
  # any other return/exception from the code module (purge, delete, ...) is
  # only watched to detect reloads, never shown
  defp collect_log({:trace_ts, _, _, {:code, _, _}, _, _}), do: :skip
  defp collect_log({:trace_ts, _, _, {:code, _, _}}), do: :skip

  defp collect_log(trace) when elem(trace, 0) in [:trace_ts, :trace], do: trace_to_props(trace)

  defp collect_log(unknown) do
    :io.format(~c"unknown trace ~p~n", [unknown])
    :skip
  end

  defp notify_module_loaded(loaded_module, %{ui_pid: pid}) do
    send(pid, {:erlyberly_module_loaded, loaded_module, module_functions2(loaded_module)})
    :ok
  end

  defp notify_trace_log(trace_log, %{ui_pid: pid}) do
    send(pid, {:erlyberly_trace_log, trace_log})
    :ok
  end

  # A 'call' trace (a normal function call, before return) as
  # {call, proplist()}.
  defp call_trace_props(pid, func, timestamp, extra_props) do
    {:call,
     [
       {:pid, :erlang.pid_to_list(pid)},
       {:reg_name, get_registered_name(pid)},
       {:fn, func},
       {:timetamp_call_us, timestamp_to_us(timestamp)} | extra_props
     ]}
  end

  # A 'return_from' trace as {return_from, proplist()}.
  defp return_from_trace_props(pid, result, timestamp) do
    {:return_from,
     [
       {:pid, :erlang.pid_to_list(pid)},
       {:reg_name, get_registered_name(pid)},
       {:result, result},
       {:timetamp_return_us, timestamp_to_us(timestamp)}
     ]}
  end

  defp trace_to_props({:trace_ts, pid, :call, {mod, func_name, [req, state]}, _, timestamp})
       when func_name in [:handle_info, :handle_cast] do
    call_trace_props(pid, {mod, func_name, [req, format_record(state, mod)]}, timestamp, [])
  end

  defp trace_to_props(
         {:trace_ts, pid, :call, {mod, :handle_call, [req, from, state]}, _, timestamp}
       ) do
    call_trace_props(
      pid,
      {mod, :handle_call, [req, from, format_record(state, mod)]},
      timestamp,
      []
    )
  end

  defp trace_to_props({:trace_ts, pid, :call, func, msg, timestamp}) do
    stack_trace =
      try do
        [{:stack_trace, stak(msg)}]
      catch
        _, _ -> []
      end

    call_trace_props(pid, func, timestamp, stack_trace)
  end

  defp trace_to_props(
         {:trace_ts, pid, :return_from, {mod, func_name, _}, {:noreply, rec}, timestamp}
       )
       when func_name in [:handle_info, :handle_cast, :handle_call] do
    return_from_trace_props(pid, {:noreply, format_record(rec, mod)}, timestamp)
  end

  defp trace_to_props(
         {:trace_ts, pid, :return_from, {mod, :handle_call, _}, {:reply, reply, rec}, timestamp}
       ) do
    return_from_trace_props(pid, {:reply, reply, format_record(rec, mod)}, timestamp)
  end

  defp trace_to_props({:trace_ts, pid, :return_from, _func, result, timestamp}) do
    return_from_trace_props(pid, result, timestamp)
  end

  defp trace_to_props({:trace_ts, pid, :exception_from, func, {class, value}, timestamp}) do
    {:exception_from,
     [
       {:pid, :erlang.pid_to_list(pid)},
       {:reg_name, get_registered_name(pid)},
       {:fn, func},
       {:exception_from, {class, value}},
       {:timetamp_return_us, timestamp_to_us(timestamp)}
     ]}
  end

  defp trace_to_props({:trace, pid, :call, func, _}) do
    {:call,
     [{:pid, :erlang.pid_to_list(pid)}, {:reg_name, get_registered_name(pid)}, {:fn, func}]}
  end

  defp trace_to_props({:trace, pid, :exception_from, func, {class, value}}) do
    {:exception_from,
     [
       {:pid, :erlang.pid_to_list(pid)},
       {:reg_name, get_registered_name(pid)},
       {:fn, func},
       {:exception_from, {class, value}}
     ]}
  end

  defp trace_to_props({:trace, pid, :return_from, func, result}) do
    {:return_from,
     [
       {:pid, :erlang.pid_to_list(pid)},
       {:reg_name, get_registered_name(pid)},
       {:fn, func},
       {:result, result}
     ]}
  end

  # a call with no message attached comes from a seq_trace pattern, which
  # only sets the seq token; nothing to show
  defp trace_to_props({:trace_ts, _pid, :call, _func, _timestamp}), do: :skip

  defp trace_to_props(unknown) do
    :io.format(~c"skipped trace_ts ~p~n", [unknown])
    :skip
  end

  # Re-apply directly (this runs inside the collector), so the traces are
  # back before the module_loaded notification goes out.
  defp reapply_traces(loaded_module, traces) do
    :lists.foreach(
      fn
        {^loaded_module, _f, _a} = trace -> set_pattern(trace, trace_match_spec(), :local)
        _ -> :ok
      end,
      traces
    )
  end

  defp trace_match_spec, do: [{:_, [], [{:message, {:process_dump}}, {:exception_trace}]}]

  def collect_trace_logs do
    case :erlang.whereis(@tcollector) do
      :undefined ->
        {:error, :tcollector_down}

      _ ->
        send(@tcollector, {:take_logs, self()})

        receive do
          {:trace_logs, logs} -> {:ok, logs}
        after
          2000 -> {:error, :tcollector_timeout}
        end
    end
  end

  defp get_registered_name(pid) do
    case :erlang.process_info(pid, :registered_name) do
      [{_, name}] -> name
      {_, name} -> name
      _ -> :undefined
    end
  end

  defp timestamp_to_us({mega, sec, micros}), do: (mega * 1_000_000 + sec) * 1_000_000 + micros

  ## ===========================================================================
  ## seq_trace
  ##
  ## This could be its own module, but keeping everything in one module keeps
  ## loading it into the remote node simple.
  ## ===========================================================================

  def seq_trace(node_pid, mod, function_name, arity, is_exported) when is_integer(arity) do
    drop_seq_token()
    {:ok, _seq_trace_pid} = ensure_seq_tracer_started(node_pid)

    scope = if is_exported, do: :global, else: :local
    _ = set_pattern({mod, function_name, :_}, seq_trace_match_spec(), scope)
    _ = trace_calls()
    # replies may have brought a token back
    drop_seq_token()
  end

  @doc """
  Remove the seq_trace pattern set by seq_trace/5 (the collector keeps
  running so logs already gathered can still be collected).
  """
  def stop_seq_trace(mod, function_name, arity, is_exported) do
    drop_seq_token()

    clear_pattern({mod, function_name, arity}, if(is_exported, do: :global, else: :local))

    drop_seq_token()
  end

  def collect_seq_trace_logs do
    drop_seq_token()

    case :erlang.whereis(@seq_tracer) do
      :undefined ->
        {:error, :down}

      _ ->
        send(@seq_tracer, {:take_seq_logs, self()})

        receive do
          {:seq_trace_logs, logs} ->
            drop_seq_token()
            {:ok, logs}
        after
          2000 -> {:error, :timeout}
        end
    end
  end

  # A seq_trace token travels with every message, across nodes too: an RPC
  # from a process that has picked one up (by receiving a traced message)
  # brings it along, and this process's own messages to the tracer and the
  # collector would then be traced and show up as events. Calls into the
  # agent never carry the caller's token on.
  defp drop_seq_token do
    _ = :seq_trace.set_token([])
    :ok
  end

  defp ensure_seq_tracer_started(remote_node) do
    ensure_tracer_started(remote_node, 500)

    case :erlang.whereis(@seq_tracer) do
      :undefined -> start_seq_tracer(remote_node)
      pid -> {:ok, pid}
    end
  end

  defp start_seq_tracer({node, _}) do
    pid =
      :proc_lib.spawn(fn ->
        # throws a badarg if the node has already closed down
        :erlang.monitor_node(node, true)
        seq_trace_collector([])
      end)

    :erlang.register(@seq_tracer, pid)
    # Set the system tracer here rather than in the collector, so it is in
    # place before seq_trace/5 returns; otherwise a call made right after
    # starting the trace can lose its events.
    :seq_trace.set_system_tracer(pid)
    {:ok, pid}
  end

  defp seq_trace_collector(trace_logs) do
    receive do
      {:nodedown, _node} ->
        :ok = stop_clear()
        true = :seq_trace.reset_trace()

      {:seq_trace, _label, trace_log, timestamp} ->
        seq_trace_collector([seq_trace_to_props(trace_log, timestamp) | trace_logs])

      {:take_seq_logs, pid} ->
        # the request may have brought a token along; the reply must not
        drop_seq_token()
        send(pid, {:seq_trace_logs, :lists.reverse(trace_logs)})
        seq_trace_collector([])

      other ->
        :io.format(~c"Erlyberly seq_trace, unexpected message: ~s ~p~n", [
          format_utc_timestamp(),
          other
        ])

        seq_trace_collector(trace_logs)
    end
  end

  defp seq_trace_to_props({msg_type, serial, from, to, message}, timestamp) do
    [
      {:msg_type, msg_type},
      {:serial, serial},
      {:from, format_pid(from)},
      {:to, format_pid(to)},
      {:message, message},
      {:timestamp, timestamp}
    ]
  end

  defp format_pid(pid) when is_pid(pid) do
    proc_info =
      try do
        :erlang.process_info(pid, :registered_name)
      catch
        _, _ -> :error
      end

    case proc_info do
      {:registered_name, reg_name} when is_atom(reg_name) -> :erlang.atom_to_list(reg_name)
      _ -> :erlang.pid_to_list(pid)
    end
  end

  defp format_pid(reg_name) when is_atom(reg_name), do: :erlang.atom_to_list(reg_name)
  defp format_pid(port) when is_port(port), do: :erlang.port_to_list(port)

  # since OTP 24 gen_server:call replies go to a process alias
  defp format_pid(ref) when is_reference(ref), do: ~c"alias " ++ :erlang.ref_to_list(ref)

  defp format_pid(other), do: :lists.flatten(:io_lib.format(~c"~p", [other]))

  defp format_utc_timestamp do
    {_, _, micro} = ts = :os.timestamp()
    {{year, month, day}, {hour, minute, second}} = :calendar.now_to_universal_time(ts)

    month_name =
      elem(
        {~c"Jan", ~c"Feb", ~c"Mar", ~c"Apr", ~c"May", ~c"Jun", ~c"Jul", ~c"Aug", ~c"Sep", ~c"Oct",
         ~c"Nov", ~c"Dec"},
        month - 1
      )

    :io_lib.format(~c"~2w ~s ~4w ~2w:~2..0w:~2..0w.~6..0w", [
      day,
      month_name,
      year,
      hour,
      minute,
      second,
      micro
    ])
  end

  # Every call of the traced function starts a seq_trace token. The `:_`
  # head matches any argument list, so one spec serves every arity (the
  # Erlang original built one per arity with dbg:fun2ms, up to 12).
  defp seq_trace_match_spec do
    [
      {:_, [],
       [
         {:set_seq_token, :send, true},
         {:set_seq_token, :receive, true},
         {:set_seq_token, :timestamp, true},
         {:set_seq_token, :print, true}
       ]}
    ]
  end

  ## ===========================================================================
  ## xref analysis
  ## ===========================================================================

  def xref_analysis(ignore_mods, m, f, a) when is_integer(a) do
    xref_analysis(ignore_mods, m, f, a, :infinity)
  end

  @doc """
  `max_depth` limits how deep the call tree goes; a node cut off by the
  limit is returned as `{MFA, more}`.
  """
  def xref_analysis(ignore_mods, m, f, a, max_depth) when is_integer(a) do
    ignore_mods_set = :gb_sets.from_list(ignore_mods)
    {:ok, xref_analysis2({m, f, a}, ignore_mods_set, :gb_sets.new(), max_depth)}
  end

  defp xref_analysis2(mfa, _ignore_mods_set, _all_calls, 0), do: {mfa, :more}

  defp xref_analysis2(mfa, ignore_mods_set, all_calls, depth) do
    if :gb_sets.is_member(mfa, all_calls) or
         :gb_sets.is_member(elem(mfa, 0), ignore_mods_set) do
      {mfa, []}
    else
      # analyze does not return ok for functions outside the xref index
      # (OTP libraries are excluded) or for modules compiled without
      # debug_info; those are leaves instead of failing the whole analysis
      case :xref.analyze(@xref, {:call, mfa}) do
        {:ok, calls} ->
          all_calls2 = :gb_sets.add(mfa, all_calls)

          analysed_calls =
            :lists.filtermap(
              fn
                ^mfa ->
                  false

                x_mfa ->
                  {true, xref_analysis2(x_mfa, ignore_mods_set, all_calls2, next_depth(depth))}
              end,
              calls
            )

          {mfa, analysed_calls}

        _error ->
          {mfa, []}
      end
    end
  end

  defp next_depth(:infinity), do: :infinity
  defp next_depth(n), do: n - 1

  @xref_excluded [
    ~c"/appmon-",
    ~c"/asn1-",
    ~c"/common_test-",
    ~c"/compiler-",
    ~c"/cos",
    ~c"/crypto-",
    ~c"/ct-",
    ~c"/debugger-",
    ~c"/dialyzer",
    ~c"/diameter",
    ~c"/edoc",
    ~c"/eldap",
    ~c"/erl_docgen",
    ~c"/erl_interface-",
    ~c"/erts",
    ~c"/et-",
    ~c"/eunit",
    ~c"/gs-",
    ~c"/hipe",
    ~c"/httpd",
    ~c"/ic-",
    ~c"/inets",
    ~c"/jinterface",
    ~c"/kernel",
    ~c"/megaco",
    ~c"/mnesia",
    ~c"/observer-",
    ~c"/odbc",
    ~c"/orber-",
    ~c"/os_mon",
    ~c"/otp_mibs",
    ~c"/parsetools",
    ~c"/percept-",
    ~c"/pman",
    ~c"/public_key",
    ~c"/reltool",
    ~c"/runtime_tools",
    ~c"/sasl",
    ~c"/snmp",
    ~c"/ssh",
    ~c"/ssl",
    ~c"/stdlib",
    ~c"/syntax_tools",
    ~c"/test_server",
    ~c"/toolbar",
    ~c"/tools",
    ~c"/tv-",
    ~c"/typer",
    ~c"/webtool",
    ~c"/wx-",
    ~c"/xmerl",
    # Elixir's own standard library
    ~c"/elixir/ebin",
    ~c"/eex/ebin",
    ~c"/ex_unit/ebin",
    ~c"/iex/ebin",
    ~c"/logger/ebin",
    ~c"/mix/ebin"
  ]

  def ensure_xref_started do
    try do
      :xref.stop(@xref)
    catch
      _, _ -> :ok
    end

    {:ok, _} = :xref.start(@xref, [{:verbose, false}, {:warnings, false}])

    code_paths =
      :lists.filter(&(not dir_contains(&1, @xref_excluded)), :lists.sort(:code.get_path()))

    :lists.foreach(&:xref.add_directory(@xref, &1, [{:warnings, false}]), code_paths)
    {:ok, :erlyberly_xref_started}
  end

  defp dir_contains(_, []), do: false

  defp dir_contains(dir, [str | tail]) do
    case :string.str(dir, str) do
      0 -> dir_contains(dir, tail)
      _ -> true
    end
  end

  @doc "Load a module if it is not already loaded."
  def try_load_module(module_name) when is_atom(module_name) do
    case :code.is_loaded(module_name) do
      false -> :code.ensure_loaded(module_name)
      {:file, _} -> :ok
    end
  end

  ## ===========================================================================
  ## view module source code
  ## ===========================================================================

  def get_source_code(what) do
    try do
      case what do
        {m, f, a} -> fun_src(m, f, a)
        mod when is_atom(mod) -> mod_src(mod)
      end
    catch
      _, e ->
        message = :io_lib.format(~c"E:~p stack:~p", [e, __STACKTRACE__])
        {:error, :erlang.list_to_binary(:lists.flatten(message))}
    end
  end

  def get_abstract_code(what) do
    try do
      case what do
        {m, f, a} -> fun_abst(m, f, a)
        mod when is_atom(mod) -> mod_abst(mod)
      end
    catch
      _, _ ->
        message = :io_lib.format(~c"~p", [__STACKTRACE__])
        {:error, :erlang.list_to_binary(:lists.flatten(message))}
    end
  end

  defp mod_src(module) do
    abstract_code(module, fn forms ->
      shown = :lists.filter(&(elem(&1, 0) in [:attribute, :function]), forms)
      text = :lists.map(&[:erl_pp.form(&1), ?\n], shown)
      {:ok, :erlang.list_to_binary(:lists.flatten(text))}
    end)
  end

  defp fun_src(mod, fun, arity) do
    abstract_code(mod, fn forms ->
      [ff] = find_function(forms, fun, arity)
      {:ok, :erlang.list_to_binary(:lists.flatten(:erl_pp.form(ff)))}
    end)
  end

  defp mod_abst(module) do
    abstract_code(module, fn forms ->
      {:ok, :erlang.list_to_binary(:lists.flatten(:io_lib.format(~c"~p", [forms])))}
    end)
  end

  defp fun_abst(mod, fun, arity) do
    abstract_code(mod, fn forms ->
      [ff] = find_function(forms, fun, arity)
      {:ok, :erlang.list_to_binary(:lists.flatten(:io_lib.format(~c"~p", [ff])))}
    end)
  end

  defp find_function(forms, fun, arity) do
    :lists.filter(
      fn
        {:function, _line, ^fun, ^arity, _} -> true
        _ -> false
      end,
      forms
    )
  end

  defp abstract_code(module, exec_fun) do
    file = :code.which(module)

    case :beam_lib.chunks(file, [:abstract_code]) do
      {:ok, {_mod, [{:abstract_code, :no_abstract_code}]}} ->
        {:ok, ~c"no_abstract_code for Module " ++ :erlang.atom_to_list(module) ++ ~c"."}

      {:ok, {_mod, [{:abstract_code, {_version, forms}}]}} ->
        exec_fun.(forms)
    end
  end

  ## ===========================================================================
  ## error_logger gen_event handler
  ## ===========================================================================

  @impl :gen_event
  def init([node]), do: {:ok, %{node: node}}

  @impl :gen_event
  def handle_event({:error_report, _, {_, :crash_report, crash_props}}, %{node: node} = state) do
    send(node, {:erlyberly_error_report, :lists.flatten(crash_props)})
    {:ok, state}
  end

  def handle_event(_, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def handle_info(_info, state), do: {:ok, state}

  @impl :gen_event
  def terminate(_reason, _state), do: :ok

  @impl :gen_event
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  ## ===========================================================================
  ## tracing `process_dump` parser from redbug
  ##
  ## https://github.com/massemanet/eper/blob/f7a1b4504f5eefc61fb9da7101fdaccc687021cd/src/redbug.erl
  ##
  ## Copyright (c) 2008-2013 mats cronqvist
  ##
  ## Permission is hereby granted, free of charge, to any person obtaining a copy
  ## of this software and associated documentation files (the "Software"), to deal
  ## in the Software without restriction, including without limitation the rights
  ## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  ## copies of the Software, and to permit persons to whom the Software is
  ## furnished to do so, subject to the following conditions:
  ##
  ## The above copyright notice and this permission notice shall be included in
  ## all copies or substantial portions of the Software.
  ## ===========================================================================

  defp stak(bin) do
    :lists.foldr(&munge/2, [], :string.tokens(:erlang.binary_to_list(bin), ~c"\n"))
  end

  defp munge(i, out) do
    case :lists.reverse(i) do
      [?., ?., ?. | _] ->
        [:truncated | out]

      _ ->
        cond do
          :string.str(i, ~c"Return addr") == 0 ->
            if :string.str(i, ~c"CP:") == 0, do: out, else: [mfaf(i) | out]

          :string.str(i, ~c"erminate process normal") == 0 ->
            [mfaf(i) | out]

          true ->
            out
        end
    end
  end

  defp mfaf(i) do
    [_, c | _] = :string.tokens(i, ~c"()+")
    stack_to_mfa(c)
  end

  defp stack_to_mfa(string) do
    case :string.tokens(string, ~c":/") do
      [mod, func, arity] ->
        {:erlang.list_to_existing_atom(fix_elixir_strings(mod)),
         :erlang.list_to_existing_atom(fix_elixir_strings(func)),
         :erlang.list_to_integer(:string.strip(fix_elixir_strings(arity)))}

      _ ->
        string
    end
  end

  defp fix_elixir_strings(string) do
    :re.replace(string, "\"|'", "", [:global, {:return, :list}])
  end

  ## ===========================================================================
  ## erlang fun decompiler
  ##
  ## Copyright (c) 2009 Serge Aleynikov
  ##
  ## Permission is hereby granted, free of charge, to any person
  ## obtaining a copy of this software and associated documentation
  ## files (the "Software"), to deal in the Software without restriction,
  ## including without limitation the rights to use, copy, modify, merge,
  ## publish, distribute, sublicense, and/or sell copies of the Software,
  ## and to permit persons to whom the Software is furnished to do
  ## so, subject to the following conditions:
  ##
  ## The above copyright notice and this permission notice shall be included
  ## in all copies or substantial portions of the Software.
  ## ===========================================================================

  @doc "Decompile a function to its source text."
  def saleyn_fun_src(fun) when is_function(fun), do: saleyn_fun_src(fun, [])

  defp saleyn_fun_src(fun, options) when is_function(fun) and is_list(options) do
    {:module, mod} = :erlang.fun_info(fun, :module)
    {:name, name} = :erlang.fun_info(fun, :name)
    {:ok, module, _beam, forms} = saleyn_get_abstract_code(mod)
    {f, arity, pos} = fun_name(name)
    saleyn_fun_src(module, name, f, arity, pos, forms, fun, options)
  end

  defp saleyn_fun_src(:erl_eval, _name, :expr, _arity, _pos, _forms, fun, options) do
    abst =
      case :erlang.fun_info(fun, :env) do
        {:env, [_, _, _, abst | _]} -> abst
        {:env, [{[], _, _, abst}]} -> abst
      end

    saleyn_fun_src2(:format, :erl_syntax.form_list(abst), options)
  end

  defp saleyn_fun_src(_module, _name, f, arity, pos, forms, _fun, options) do
    clauses =
      :lists.filtermap(
        fn
          {:function, _, ^f, ^arity, cs} -> {true, cs}
          _ -> false
        end,
        forms
      )

    ast = :lists.nth(pos, funs(:lists.concat(clauses)))
    saleyn_fun_src2(:undefined, ast, options)
  end

  defp saleyn_fun_src2(envelope, ast, _options) do
    text = :erl_prettypr.format(ast)

    case envelope do
      :format -> ~c"fun " ++ text ++ ~c" end."
      _ -> text ++ ~c"."
    end
  end

  defp fun_name(name) do
    [fs, as, _, rs] = :string.tokens(:erlang.atom_to_list(name), ~c"-/")
    {:erlang.list_to_atom(fs), :erlang.list_to_integer(as), :erlang.list_to_integer(rs) + 1}
  end

  defp funs(l) do
    :lists.reverse(
      :lists.foldl(
        fn
          {:fun, _, _} = f, acc -> [f | acc]
          t, acc when is_tuple(t) -> funs(:lists.flatten(:erlang.tuple_to_list(t))) ++ acc
          _, acc -> acc
        end,
        [],
        l
      )
    )
  end

  defp saleyn_get_abstract_code(module) when is_atom(module) do
    {:module, _} = :code.ensure_loaded(module)
    saleyn_get_abstract_code(:code.which(module))
  end

  defp saleyn_get_abstract_code(beam) when is_list(beam) do
    basename = :filename.basename(beam, ~c".beam")

    case :beam_lib.chunks(beam, [:abstract_code]) do
      {:ok, {module, [{:abstract_code, {_, ac}}]}} -> {:ok, module, basename, ac}
      other -> other
    end
  end
end
