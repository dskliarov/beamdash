%%% exberly agent: loaded into the node being inspected.
%%%
%%% Keep this module small and dependency-free. It runs inside the target
%%% node, so it must only use modules that ship with ERTS/kernel/stdlib.
%%% Work is done here (one RPC per screen refresh) instead of making one
%%% RPC per process from the GUI node.
-module(exberly_agent).

-export([version/0, node_info/0, system_info/0, processes/0]).
-export([load_sampler_start/2, load_sample/0]).
-export([applications/0, app_tree/1]).
-export([process_details/2, garbage_collect/1]).
-export([sys_trace/3, sys_trace_stop_all/0, sys_event/3]).
-export([tprof_available/0, tprof_start/4, tprof_collect/1, tprof_stop/0]).
-export([recon_available/0, memory_snapshot/0, top_processes/2, gc_all/0,
         binary_leaks/1, ets_tables/0, process_state/2]).
-export([get_state/1, supervision_tree/1]).
-export([gc_snapshot/0, gc_trace_start/3]).

-define(SUMMARY_KEYS, [registered_name, initial_call, current_function,
                       memory, reductions, message_queue_len, status]).

%% Where proc_lib keeps a process's real entry point. OTP 26+ can read one
%% dictionary key in the same process_info call as everything else.
-define(INITIAL_CALL_KEY, {dictionary, '$initial_call'}).

version() -> 14.

node_info() ->
    {WallClockMs, _} = erlang:statistics(wall_clock),
    #{node => node(),
      otp_release => list_to_binary(erlang:system_info(otp_release)),
      erts_version => list_to_binary(erlang:system_info(version)),
      process_count => erlang:system_info(process_count),
      memory_total => erlang:memory(total),
      schedulers => erlang:system_info(schedulers_online),
      uptime_ms => WallClockMs,
      agent_version => version()}.

%% What Observer's System tab shows (observer_backend:sys_info/0, which
%% needs runtime_tools on the target; this does not). Each value is read
%% on its own: one an older release lacks is `undefined`, not an error.
system_info() ->
    S = fun(Key) -> try erlang:system_info(Key) catch _:_ -> undefined end end,
    Str = fun(V) when is_list(V) -> unicode:characters_to_binary(V); (V) -> V end,
    Memory = try maps:from_list(erlang:memory()) catch _:_ -> #{} end,
    Online = S(schedulers_online),
    Available = case S(multi_scheduling) of
                    enabled -> Online;
                    _ -> 1
                end,
    {{input, In}, {output, Out}} = erlang:statistics(io),
    {UptimeMs, _} = erlang:statistics(wall_clock),
    #{uptime_ms => UptimeMs,
      run_queue => erlang:statistics(run_queue),
      io_input => In,
      io_output => Out,
      logical_processors => S(logical_processors),
      logical_processors_online => S(logical_processors_online),
      logical_processors_available => S(logical_processors_available),
      schedulers => S(schedulers),
      schedulers_online => Online,
      schedulers_available => Available,
      otp_release => Str(S(otp_release)),
      version => Str(S(version)),
      system_architecture => Str(S(system_architecture)),
      kernel_poll => S(kernel_poll),
      smp_support => S(smp_support),
      threads => S(threads),
      thread_pool_size => S(thread_pool_size),
      wordsize_internal => S({wordsize, internal}),
      wordsize_external => S({wordsize, external}),
      atom_count => S(atom_count),
      atom_limit => S(atom_limit),
      process_count => S(process_count),
      process_limit => S(process_limit),
      port_count => S(port_count),
      port_limit => S(port_limit),
      ets_count => S(ets_count),
      ets_limit => S(ets_limit),
      dist_buf_busy_limit => S(dist_buf_busy_limit),
      memory => Memory}.

%% Observer's Load Charts (observer_backend:fetch_stats/2): a process on
%% the target sends a sample to Receiver every IntervalMs. It keeps
%% scheduler_wall_time on while it runs (the flag is held per process) and
%% stops, turning it off, when Receiver goes away: the page closed or the
%% connection dropped.
load_sampler_start(Receiver, IntervalMs) when is_pid(Receiver), is_integer(IntervalMs) ->
    {ok, spawn(fun() -> load_sampler_init(Receiver, IntervalMs) end)}.

load_sampler_init(Receiver, IntervalMs) ->
    Ref = erlang:monitor(process, Receiver),
    erlang:system_flag(scheduler_wall_time, true),
    load_sampler_loop(Receiver, Ref, IntervalMs).

load_sampler_loop(Receiver, Ref, IntervalMs) ->
    Receiver ! {exberly_load, self(), load_sample()},
    receive
        {'DOWN', Ref, process, _, _} -> erlang:system_flag(scheduler_wall_time, false), ok;
        stop -> erlang:system_flag(scheduler_wall_time, false), ok
    after IntervalMs ->
        load_sampler_loop(Receiver, Ref, IntervalMs)
    end.

load_sample() ->
    {{input, In}, {output, Out}} = erlang:statistics(io),
    Dirty = try erlang:system_info(dirty_cpu_schedulers) catch _:_ -> 0 end,
    #{at_ms => erlang:monotonic_time(millisecond),
      %% [{Id, Active, Total}] for normal and dirty CPU schedulers, or undefined
      scheduler_wall_time => erlang:statistics(scheduler_wall_time),
      schedulers => erlang:system_info(schedulers),
      dirty_cpu_schedulers => Dirty,
      io_input => In,
      io_output => Out,
      memory => try maps:from_list(erlang:memory()) catch _:_ -> #{} end}.

%% Observer's Applications tab (appmon_info, which needs runtime_tools on
%% the target; this does not). The running applications that have an
%% application master, as appmon_info:calc_app_on_node/0 lists them.
applications() ->
    Str = fun(V) -> try unicode:characters_to_binary(V) catch _:_ -> <<>> end end,
    [#{name => Name, description => Str(Desc), vsn => Str(Vsn), master => Master}
     || {Name, Desc, Vsn} <- application:which_applications(),
        Master <- [catch application_controller:get_master(Name)],
        is_pid(Master)].

%% The process tree of an application, found as appmon_info's default
%% "link" mode does (calc_app_tree/2): from the application master, follow
%% each process's links. A linked process is a child (primary link) when
%% its '$ancestors' start with the parent, or, without ancestors, when it
%% has the application's group leader and is not already queued; other
%% links are secondary. Ports, other nodes' processes and the runtime's
%% own processes are left out. At most 5000 processes.
app_tree(Name) ->
    case catch application_controller:get_master(Name) of
        Root when is_pid(Root) ->
            Avoid = [P || N <- [application_controller, init, erl_prim_loader],
                          P <- [whereis(N)], is_pid(P)],
            {Seen, Links, Extra} =
                app_walk(queue:from_list([Root]), #{}, [], [], app_groupl(Root), Avoid),
            Procs = [#{pid => P, name => app_reg_name(P), label => app_label(P)}
                     || P <- maps:keys(Seen)],
            #{root => Root, procs => Procs,
              links => lists:reverse(Links), extra => lists:reverse(Extra)};
        _ ->
            undefined
    end.

app_walk(Q0, Seen, Links, Extra, GL, Avoid) ->
    case queue:out(Q0) of
        {empty, _} ->
            {Seen, Links, Extra};
        {{value, P}, Q} when is_map_key(P, Seen) ->
            app_walk(Q, Seen, Links, Extra, GL, Avoid);
        {{value, _}, Q} when map_size(Seen) >= 5000 ->
            app_walk(Q, Seen, Links, Extra, GL, Avoid);
        {{value, P}, Q1} ->
            Kids = case process_info(P, links) of
                       {links, Ls} -> lists:reverse(Ls);
                       _ -> []
                   end,
            {Q2, Links2, Extra2} =
                lists:foldr(fun(C, Acc) -> app_child(C, P, Seen, GL, Avoid, Acc) end,
                            {Q1, Links, Extra}, Kids),
            app_walk(Q2, Seen#{P => true}, Links2, Extra2, GL, Avoid)
    end.

app_child(C, _Paren, Seen, _GL, _Avoid, Acc)
  when not is_pid(C); is_map_key(C, Seen) ->
    Acc;
app_child(C, Paren, _Seen, GL, Avoid, {Q, Links, Extra} = Acc) ->
    case node(C) =:= node() andalso not lists:member(C, Avoid) of
        false ->
            Acc;
        true ->
            Prim = {queue:in(C, Q), [{Paren, C} | Links], Extra},
            Sec = {Q, Links, [{Paren, C} | Extra]},
            case app_ancestor(C) of
                Paren -> Prim;
                none ->
                    case app_groupl(C) of
                        G when G =:= GL; G =:= nil ->
                            case queue:member(C, Q) of
                                true -> Sec;
                                false -> Prim
                            end;
                        _ -> Acc
                    end;
                _ -> Sec
            end
    end.

%% The first of a proc_lib process's '$ancestors' (a pid, or undefined
%% for a name no longer registered), or none without ancestors.
app_ancestor(P) ->
    case process_info(P, dictionary) of
        {dictionary, D} ->
            case lists:keyfind('$ancestors', 1, D) of
                {_, [A | _]} when is_atom(A) -> whereis(A);
                {_, [A | _]} -> A;
                _ -> none
            end;
        _ -> none
    end.

app_groupl(P) ->
    case process_info(P, group_leader) of
        {group_leader, GL} -> GL;
        _ -> nil
    end.

app_reg_name(P) ->
    case process_info(P, registered_name) of
        {registered_name, N} -> N;
        _ -> undefined
    end.

%% proc_lib:set_label/1 (OTP 27+)
app_label(P) ->
    try proc_lib:get_label(P) of
        undefined -> undefined;
        L -> unicode:characters_to_binary(io_lib:format("~0tp", [L]))
    catch _:_ -> undefined
    end.

%% One map per live process. Processes that exit while we walk the list
%% are skipped. Module behaviours are looked up once per module per call.
%%
%% Since OTP 21, process_info/2 on another process is a signal that the
%% process itself handles, so each call costs the inspected process a
%% little work. Everything is asked for in a single call per process.
processes() ->
    Keys = case dict_key_supported() of
               true -> ?SUMMARY_KEYS ++ [?INITIAL_CALL_KEY];
               false -> ?SUMMARY_KEYS
           end,
    {Procs, _Cache} =
        lists:foldl(
          fun(Pid, {Acc, Cache}) ->
                  case summary(Pid, Keys, Cache) of
                      false -> {Acc, Cache};
                      {Summary, Cache1} -> {[Summary | Acc], Cache1}
                  end
          end, {[], #{}}, erlang:processes()),
    lists:reverse(Procs).

summary(Pid, Keys, Cache) ->
    case erlang:process_info(Pid, Keys) of
        undefined ->
            false;
        Props ->
            Get = fun(K) -> proplists:get_value(K, Props) end,
            InitialCall = initial_call(Pid, Get(initial_call), Props),
            CurrentFunction = Get(current_function),
            {Kind, Cache1} = kind(InitialCall, CurrentFunction, Cache),
            {#{pid => Pid,
               registered_name => registered_name(Get(registered_name)),
               initial_call => InitialCall,
               current_function => CurrentFunction,
               kind => Kind,
               memory => Get(memory),
               reductions => Get(reductions),
               message_queue_len => Get(message_queue_len),
               status => Get(status)}, Cache1}
    end.

%% What OTP behaviour a process runs: gen_server, gen_statem, gen_event,
%% supervisor, or nil. Decided without messaging the process:
%%  - supervisors start as supervisor:init/1 (their initial call is
%%    {supervisor, CallbackModule, 1}), supervisor bridges likewise;
%%    Elixir's DynamicSupervisor is a supervisor too. All of them are
%%    gen_servers underneath, but are not reported as such;
%%  - other proc_lib processes start as CallbackModule:init/1, so the
%%    module's -behaviour attributes (gen_server, or Elixir's GenServer)
%%    tell what it is;
%%  - failing that (no behaviour declared), the callbacks it exports:
%%    callback_mode/0 exists only for gen_statem;
%%  - and last, an idle process waiting inside gen_server or gen_statem
%%    gives it away (any function there: their loop functions are named
%%    differently in different OTP releases).
kind({supervisor, _, _}, _Current, Cache) ->
    {supervisor, Cache};
kind({supervisor_bridge, _, _}, _Current, Cache) ->
    {supervisor, Cache};
kind({'Elixir.DynamicSupervisor', init, 1}, _Current, Cache) ->
    {supervisor, Cache};
kind({gen_event, init_it, _}, _Current, Cache) ->
    {gen_event, Cache};
kind({Mod, init, 1}, Current, Cache) when is_atom(Mod) ->
    {Behaviours, Cache1} = behaviours(Mod, Cache),
    {from_behaviours(Behaviours, Current), Cache1};
kind(_InitialCall, Current, Cache) ->
    {from_current(Current), Cache}.

from_behaviours([], Current) ->
    from_current(Current);
from_behaviours(Behaviours, Current) ->
    Has = fun(Names) -> lists:any(fun(N) -> lists:member(N, Behaviours) end, Names) end,
    Kinds = [{gen_server, [gen_server, 'Elixir.GenServer']},
             {gen_statem, [gen_statem]},
             {gen_event, [gen_event]},
             {supervisor, [supervisor, 'Elixir.Supervisor']}],
    case [Kind || {Kind, Names} <- Kinds, Has(Names)] of
        [Kind | _] -> Kind;
        [] -> from_current(Current)
    end.

from_current({gen_server, _, _}) -> gen_server;
from_current({gen_statem, _, _}) -> gen_statem;
from_current(_) -> nil.

behaviours(Mod, Cache) ->
    case Cache of
        #{Mod := Behaviours} ->
            {Behaviours, Cache};
        _ ->
            Behaviours =
                case declared_behaviours(Mod) of
                    [] -> exported_behaviour(Mod);
                    Declared -> Declared
                end,
            {Behaviours, Cache#{Mod => Behaviours}}
    end.

declared_behaviours(Mod) ->
    try Mod:module_info(attributes) of
        Attrs ->
            lists:append([V || {K, V} <- Attrs,
                               K =:= behaviour orelse K =:= behavior,
                               is_list(V)])
    catch
        _:_ -> []
    end.

%% For modules that declare no behaviour: callback_mode/0 is a callback
%% only gen_statem has.
exported_behaviour(Mod) ->
    try Mod:module_info(exports) of
        Exports ->
            case lists:member({callback_mode, 0}, Exports) of
                true -> [gen_statem];
                false -> []
            end
    catch
        _:_ -> []
    end.

%% process_info returns [] for unregistered processes. 'nil' reads as nil
%% on the Elixir side.
registered_name([]) -> nil;
registered_name(Name) -> Name.

%% Processes started through proc_lib (gen_server, gen_statem, ...) all
%% report proc_lib:init_p/5; the real entry point is in their dictionary.
%% Props already holds it when the node supports reading one dictionary
%% key (OTP 26+); older nodes need a second call, for those processes only.
initial_call(Pid, {proc_lib, init_p, 5} = Default, Props) ->
    case lists:keyfind(?INITIAL_CALL_KEY, 1, Props) of
        {_, {M, F, A}} ->
            {M, F, A};
        {_, _} ->
            Default;
        false ->
            case erlang:process_info(Pid, dictionary) of
                {dictionary, Dict} ->
                    case lists:keyfind('$initial_call', 1, Dict) of
                        {_, {M, F, A}} -> {M, F, A};
                        false -> Default
                    end;
                undefined ->
                    Default
            end
    end;
initial_call(_Pid, InitialCall, _Props) ->
    InitialCall.

%% Asking about ourselves is not a signal, so this check is free.
dict_key_supported() ->
    try erlang:process_info(self(), ?INITIAL_CALL_KEY) of
        _ -> true
    catch
        error:badarg -> false
    end.

%%% ============================================================================
%%% process details: memory, garbage collection, reductions, mailbox
%%% ============================================================================

-define(DETAIL_KEYS, [registered_name, initial_call, current_function, status,
                      memory, heap_size, total_heap_size, stack_size,
                      reductions, message_queue_len, garbage_collection,
                      binary, links, monitors, monitored_by, trap_exit,
                      priority, group_leader]).

%% At most this many queued messages are returned.
-define(SHOWN_MESSAGES, 100).

%% Keys an old OTP release may not support. Normally asked for together
%% with ?DETAIL_KEYS; one by one only if that call is refused.
-define(OPTIONAL_KEYS, [garbage_collection_info, message_queue_data,
                        current_stacktrace]).

%% Everything about one process, sizes in bytes, or 'undefined' when it is
%% gone. Queued messages are copied only when there are at most
%% MaxMessages of them (copying a huge mailbox would add to the trouble),
%% and only the first ?SHOWN_MESSAGES are returned.
%%
%% On a current node this is one process_info call (a second one only to
%% copy queued messages), as each call costs the process some work.
process_details(Pid, MaxMessages) when is_pid(Pid), is_integer(MaxMessages) ->
    case detail_info(Pid) of
        undefined ->
            undefined;
        {Props, Optional} ->
            Get = fun(K) -> proplists:get_value(K, Props) end,
            Word = erlang:system_info(wordsize),
            Binaries = Get(binary),
            QueueLen = Get(message_queue_len),
            #{pid => Pid,
              sampled_at_us => erlang:monotonic_time(microsecond),
              registered_name => registered_name(Get(registered_name)),
              initial_call => initial_call(Pid, Get(initial_call), Props),
              current_function => Get(current_function),
              current_stacktrace => maps:get(current_stacktrace, Optional, []),
              status => Get(status),
              priority => Get(priority),
              trap_exit => Get(trap_exit),
              group_leader => Get(group_leader),
              links => Get(links),
              monitors => Get(monitors),
              monitored_by => Get(monitored_by),
              reductions => Get(reductions),
              memory => #{total => Get(memory),
                          heap => Get(heap_size) * Word,
                          total_heap => Get(total_heap_size) * Word,
                          stack => Get(stack_size) * Word,
                          binary_count => length(Binaries),
                          binary_bytes => lists:sum([Size || {_, Size, _} <- Binaries]),
                          message_queue_data => maps:get(message_queue_data, Optional, undefined)},
              gc => gc_info(Get(garbage_collection),
                            maps:get(garbage_collection_info, Optional, []), Word),
              mailbox => mailbox(Pid, QueueLen, MaxMessages)}
    end.

%% {Props, Optional} or undefined. Optional is a map of the ?OPTIONAL_KEYS
%% the node supports.
detail_info(Pid) ->
    Extra = case dict_key_supported() of
                true -> [?INITIAL_CALL_KEY];
                false -> []
            end,
    try erlang:process_info(Pid, ?DETAIL_KEYS ++ ?OPTIONAL_KEYS ++ Extra) of
        undefined ->
            undefined;
        Props ->
            {Props, maps:from_list([KV || {K, _} = KV <- Props,
                                          lists:member(K, ?OPTIONAL_KEYS)])}
    catch
        error:badarg ->
            case erlang:process_info(Pid, ?DETAIL_KEYS) of
                undefined -> undefined;
                Props -> {Props, optional_info(Pid)}
            end
    end.

optional_info(Pid) ->
    lists:foldl(
      fun(Key, Acc) ->
              try erlang:process_info(Pid, Key) of
                  {Key, Value} -> Acc#{Key => Value};
                  _ -> Acc
              catch
                  error:badarg -> Acc
              end
      end, #{}, ?OPTIONAL_KEYS).

%% garbage_collection: settings and minor_gcs (minor collections since
%% the last fullsweep). garbage_collection_info (OTP 19+): current sizes,
%% in words.
gc_info(Settings, Info, Word) ->
    Bytes = fun(K) ->
                    case proplists:get_value(K, Info) of
                        undefined -> undefined;
                        Words -> Words * Word
                    end
            end,
    #{minor_gcs => proplists:get_value(minor_gcs, Settings),
      fullsweep_after => proplists:get_value(fullsweep_after, Settings),
      min_heap_size => words(proplists:get_value(min_heap_size, Settings), Word),
      min_bin_vheap_size => words(proplists:get_value(min_bin_vheap_size, Settings), Word),
      max_heap_size => max_heap(proplists:get_value(max_heap_size, Settings), Word),
      heap_block_size => Bytes(heap_block_size),
      old_heap_size => Bytes(old_heap_size),
      old_heap_block_size => Bytes(old_heap_block_size),
      mbuf_size => Bytes(mbuf_size),
      recent_size => Bytes(recent_size),
      bin_vheap_size => Bytes(bin_vheap_size),
      bin_old_vheap_size => Bytes(bin_old_vheap_size)}.

words(undefined, _Word) -> undefined;
words(N, Word) -> N * Word.

max_heap(#{size := 0}, _Word) -> unlimited;
max_heap(#{size := Size}, Word) -> Size * Word;
max_heap(_, _Word) -> undefined.

mailbox(_Pid, Len, Max) when Len > Max ->
    #{length => Len, messages => not_fetched, limit => Max};
mailbox(_Pid, 0, Max) ->
    #{length => 0, messages => [], limit => Max};
mailbox(Pid, Len, Max) ->
    Messages = case erlang:process_info(Pid, messages) of
                   {messages, Ms} -> lists:sublist(Ms, ?SHOWN_MESSAGES);
                   undefined -> []
               end,
    #{length => Len, messages => Messages, limit => Max}.

%% Force a garbage collection of Pid; returns its memory before and after.
garbage_collect(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, memory) of
        undefined ->
            undefined;
        {memory, Before} ->
            true = erlang:garbage_collect(Pid),
            case erlang:process_info(Pid, memory) of
                {memory, After} -> #{before => Before, 'after' => After};
                undefined -> undefined
            end
    end.

%%% ============================================================================
%%% sys:trace for OTP processes (gen_server, gen_statem, gen_event, supervisor)
%%% ============================================================================
%%
%% sys_trace(Pid, true, Owner) calls sys:trace(Pid, true), which makes the
%% process print each event it handles ("*DBG* ... got call ...") on its own
%% console, and also installs a sys debug function that copies every event
%% to a collector process here. The collector sends them on to Owner (an
%% exberly process) in batches. sys_trace(Pid, false, _) undoes both.
%%
%% The collector watches Owner: if exberly goes away (disconnect, crash,
%% lost connection) it turns tracing off on every process it was watching,
%% so nothing is left tracing after exberly is gone.

-define(SYS_COLLECTOR, exberly_sys_collector).
-define(SYS_FUNC_ID, exberly).
-define(SYS_TIMEOUT, 5000).
%% Events are sent on at most every ?SYS_FLUSH_MS, at most
%% ?SYS_MAX_PER_FLUSH at a time (1,000 a second); the rest are counted
%% as dropped.
-define(SYS_FLUSH_MS, 200).
-define(SYS_MAX_PER_FLUSH, 200).

sys_trace(Pid, true, Owner) when is_pid(Pid), is_pid(Owner) ->
    Collector = sys_collector(Owner),
    Fun = fun ?MODULE:sys_event/3,
    sys_request(Pid, fun() ->
                         %% replace a function left by an earlier session
                         ok = sys:remove(Pid, ?SYS_FUNC_ID, ?SYS_TIMEOUT),
                         ok = sys:install(Pid, {?SYS_FUNC_ID, Fun, Collector}, ?SYS_TIMEOUT),
                         ok = sys:trace(Pid, true, ?SYS_TIMEOUT),
                         Collector ! {watch, Pid},
                         ok
                 end);
sys_trace(Pid, false, _Owner) when is_pid(Pid) ->
    case whereis(?SYS_COLLECTOR) of
        undefined -> ok;
        Collector -> Collector ! {unwatch, Pid}
    end,
    sys_request(Pid, fun() -> sys_off(Pid, ?SYS_TIMEOUT) end).

%% A process busy with something else (or blocked) answers sys requests
%% only when it gets back to its receive loop. The request stays in its
%% mailbox, so after a timeout tracing is switched off behind it: a late
%% "on" must not take effect when exberly reported a failure.
sys_request(Pid, Fun) ->
    try
        Fun()
    catch
        exit:{noproc, _} -> {error, noproc};
        exit:{timeout, _} -> sys_off_later(Pid), {error, timeout};
        exit:{Reason, _} -> sys_off_later(Pid), {error, Reason};
        error:Reason -> sys_off_later(Pid), {error, Reason}
    end.

sys_off(Pid, Timeout) ->
    ok = sys:remove(Pid, ?SYS_FUNC_ID, Timeout),
    ok = sys:trace(Pid, false, Timeout).

sys_off_later(Pid) ->
    spawn(fun() -> catch sys_off(Pid, infinity) end),
    ok.

%% Called by sys inside the traced process for every event. Returning
%% 'done' removes the function, so once the collector is gone the traced
%% process stops paying for it.
sys_event(Collector, Event, _ProcState) ->
    case erlang:is_process_alive(Collector) of
        true ->
            Collector ! {sys_event, self(), erlang:system_time(microsecond), Event},
            Collector;
        false ->
            done
    end.

%% Turns tracing off everywhere (exberly disconnecting).
sys_trace_stop_all() ->
    case whereis(?SYS_COLLECTOR) of
        undefined ->
            ok;
        Collector ->
            Ref = erlang:monitor(process, Collector),
            Collector ! stop_all,
            receive {'DOWN', Ref, process, Collector, _} -> ok
            after ?SYS_TIMEOUT -> erlang:demonitor(Ref, [flush]), ok
            end
    end.

sys_collector(Owner) ->
    case whereis(?SYS_COLLECTOR) of
        undefined ->
            Self = self(),
            Pid = spawn(fun() ->
                                case catch register(?SYS_COLLECTOR, self()) of
                                    true ->
                                        Self ! {self(), registered},
                                        collector_loop(collector_owner(#{watched => #{},
                                                                         buf => [],
                                                                         n => 0,
                                                                         dropped => 0},
                                                                       Owner));
                                    _ ->
                                        Self ! {self(), taken}
                                end
                        end),
            receive
                {Pid, registered} -> Pid;
                {Pid, taken} -> sys_collector(Owner)
            end;
        Pid ->
            Pid ! {owner, Owner},
            Pid
    end.

collector_owner(State, Owner) ->
    case State of
        #{owner_ref := OldRef} -> erlang:demonitor(OldRef, [flush]);
        _ -> ok
    end,
    State#{owner => Owner, owner_ref => erlang:monitor(process, Owner)}.

collector_loop(#{owner := Owner, owner_ref := OwnerRef, watched := Watched} = S) ->
    receive
        {sys_event, Pid, At, Event} ->
            collector_loop(buffer({Pid, At, Event}, S));
        flush ->
            collector_loop(flush(S));
        {watch, Pid} ->
            case Watched of
                #{Pid := _} -> collector_loop(S);
                _ -> collector_loop(S#{watched := Watched#{Pid => erlang:monitor(process, Pid)}})
            end;
        {unwatch, Pid} ->
            case maps:take(Pid, Watched) of
                {Ref, Rest} ->
                    erlang:demonitor(Ref, [flush]),
                    collector_loop(S#{watched := Rest});
                error ->
                    collector_loop(S)
            end;
        {owner, Owner} ->
            collector_loop(S);
        {owner, NewOwner} ->
            collector_loop(collector_owner(S, NewOwner));
        {'DOWN', OwnerRef, process, Owner, _} ->
            collector_stop(Watched);
        stop_all ->
            collector_stop(Watched);
        {'DOWN', _Ref, process, Pid, Reason} when is_map_key(Pid, Watched) ->
            S1 = buffer({Pid, erlang:system_time(microsecond), {exberly_exited, Reason}},
                        S#{watched := maps:remove(Pid, Watched)}),
            collector_loop(flush(S1));
        _Other ->
            collector_loop(S)
    end.

buffer(Entry, #{buf := [], n := 0} = S) ->
    erlang:send_after(?SYS_FLUSH_MS, self(), flush),
    S#{buf := [Entry], n := 1};
buffer({_, _, {exberly_exited, _}} = Entry, #{buf := Buf, n := N} = S) ->
    S#{buf := [Entry | Buf], n := N + 1};
buffer(_Entry, #{n := N, dropped := D} = S) when N >= ?SYS_MAX_PER_FLUSH ->
    S#{dropped := D + 1};
buffer(Entry, #{buf := Buf, n := N} = S) ->
    S#{buf := [Entry | Buf], n := N + 1}.

flush(#{buf := [], dropped := 0} = S) ->
    S;
flush(#{owner := Owner, buf := Buf, dropped := Dropped} = S) ->
    %% noconnect: never make this node dial exberly's
    erlang:send(Owner, {exberly_sys_events, lists:reverse(Buf), Dropped}, [noconnect]),
    S#{buf := [], n := 0, dropped := 0}.

collector_stop(Watched) ->
    [sys_off_later(Pid) || Pid <- maps:keys(Watched)],
    exit(normal).

%%% ============================================================================
%%% Profiling with tprof (OTP 27+)
%%% ============================================================================
%%
%% tprof runs as an unregistered server in its own trace session (so it
%% does not clash with dbg, or with a tprof the user runs themselves),
%% registered here as exberly_tprof. A guard process watches the exberly
%% process that started it and stops profiling if that goes away, so a
%% profile can never be left running.

-define(TPROF, exberly_tprof).
-define(TPROF_GUARD, exberly_tprof_guard).
%% Functions returned per view (by measurement); the rest are summed up.
-define(TPROF_MAX_LINES, 500).
-define(TPROF_MAX_PROCS, 50).

tprof_available() ->
    case code:ensure_loaded(tprof) of
        {module, tprof} -> true;
        {error, _} -> {false, list_to_binary(erlang:system_info(otp_release))}
    end.

%% Type: call_count | call_time | call_memory.
%% Patterns: [{Mod, Fun, Arity}] with '_' as wildcards.
%% Procs: all | new | existing | [pid() | atom()] (followed into processes
%% they spawn).
tprof_start(Type, Patterns, Procs, Owner) when is_list(Patterns), is_pid(Owner) ->
    _ = tprof_stop(),
    case tprof:start(#{type => Type, session => ?TPROF}) of
        {ok, Server} ->
            true = register(?TPROF, Server),
            %% set_pattern returns how many functions it matched
            Unmatched =
                [{M, F, A} || {M, F, A} <- Patterns,
                              not is_integer(N = tprof:set_pattern(Server, M, F, A))
                                  orelse N =:= 0],
            %% call_count counts calls from every process; the others
            %% measure only the traced processes
            Traced = case Type of
                         call_count -> all;
                         _ -> tprof:enable_trace(Server, Procs, #{set_on_spawn => true})
                     end,
            Guard = spawn(fun() -> tprof_guard(Owner, Server) end),
            true = register(?TPROF_GUARD, Guard),
            {ok, #{traced => tprof_traced(Traced),
                   unmatched => Unmatched,
                   functions => tprof_function_count(Server)}};
        {error, Reason} ->
            {error, Reason}
    end.

tprof_traced(N) when is_integer(N) -> #{count => N, failed => []};
tprof_traced({N, Failed}) -> #{count => N, failed => Failed};
tprof_traced(all) -> all.

tprof_function_count(Server) ->
    case tprof:get_trace_map(Server) of
        all -> all;
        Map -> lists:sum([length(Fs) || Fs <- maps:values(Map)])
    end.

%% What has been measured so far (profiling keeps running). Measurements:
%% call counts, microseconds (call_time) or words (call_memory).
tprof_collect(PerProcess) ->
    case whereis(?TPROF) of
        undefined ->
            {error, not_running};
        Server ->
            {Type, Raw} = Collected = tprof:collect(Server),
            #{all := {Type, Total, Lines}} = tprof:inspect(Collected, total, {measurement, descending}),
            Processes =
                case PerProcess andalso Type =/= call_count of
                    true ->
                        ByPid = tprof:inspect(Collected, process, {measurement, descending}),
                        Sorted = lists:reverse(lists:keysort(2,
                                     [{Pid, T, L} || {Pid, {_, T, L}} <- maps:to_list(ByPid)])),
                        [#{pid => Pid, name => tprof_name(Pid),
                           total => T, lines => tprof_lines(L)}
                         || {Pid, T, L} <- lists:sublist(Sorted, ?TPROF_MAX_PROCS)];
                    false ->
                        []
                end,
            {ok, #{type => Type,
                   total => Total,
                   lines => tprof_lines(Lines),
                   functions => length(Raw),
                   processes => Processes,
                   word_size => erlang:system_info(wordsize)}}
    end.

tprof_name(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, Name} -> Name;
        _ -> nil
    end.

tprof_lines(Lines) ->
    [#{mfa => {M, F, A}, calls => C, measurement => Me, per_call => PC, percent => Pct}
     || {M, {F, A}, C, Me, PC, Pct} <- lists:sublist(Lines, ?TPROF_MAX_LINES)].

tprof_stop() ->
    case whereis(?TPROF_GUARD) of
        undefined -> ok;
        Guard -> unregister(?TPROF_GUARD), exit(Guard, kill)
    end,
    case whereis(?TPROF) of
        undefined -> ok;
        Server -> catch tprof:stop(Server), ok
    end.

tprof_guard(Owner, Server) ->
    OwnerRef = erlang:monitor(process, Owner),
    ServerRef = erlang:monitor(process, Server),
    receive
        {'DOWN', OwnerRef, process, _, _} -> catch tprof:stop(Server), ok;
        {'DOWN', ServerRef, process, _, _} -> ok
    end.

%%% ============================================================================
%%% Memory: snapshot and leak investigation
%%% ============================================================================
%%
%% recon (https://hex.pm/packages/recon) is used when it is loaded on the
%% node (its own copy, or the one exberly loads): recon:proc_count/2,
%% recon:bin_leak/1 and recon_alloc:memory/1. Without it, the same
%% measurements are made here, so the page works either way; every result
%% says which was used.

recon_available() ->
    case code:ensure_loaded(recon) of
        {module, recon} -> erlang:function_exported(recon, proc_count, 2);
        _ -> false
    end.

%% erlang:memory() plus the counts and limits that go with it.
memory_snapshot() ->
    Alloc = case recon_available() andalso code:ensure_loaded(recon_alloc) of
                {module, recon_alloc} ->
                    try #{allocated => recon_alloc:memory(allocated),
                          used => recon_alloc:memory(used),
                          usage => recon_alloc:memory(usage)}
                    catch _:_ -> nil
                    end;
                _ -> nil   % nil reads as nil on the Elixir side
            end,
    #{memory => maps:from_list(erlang:memory()),
      sampled_at_ms => erlang:system_time(millisecond),
      atom_count => erlang:system_info(atom_count),
      atom_limit => erlang:system_info(atom_limit),
      process_count => erlang:system_info(process_count),
      process_limit => erlang:system_info(process_limit),
      ets_count => length(ets:all()),
      ets_limit => ets_limit(),
      module_count => length(code:all_loaded()),
      word_size => erlang:system_info(wordsize),
      alloc => Alloc,
      recon => recon_available()}.

ets_limit() ->
    try erlang:system_info(ets_limit) catch _:_ -> nil end.

%% The N processes with the most Attr: memory | message_queue_len |
%% binary_memory | reductions | total_heap_size. Like recon:proc_count/2.
top_processes(Attr, N) when is_atom(Attr), is_integer(N) ->
    case recon_available() of
        true ->
            {recon, [proc_entry(Pid, Val, Info) || {Pid, Val, Info} <- recon:proc_count(Attr, N)]};
        false ->
            Vals = lists:foldl(
                     fun(Pid, Acc) ->
                             case proc_attr(Pid, Attr) of
                                 undefined -> Acc;
                                 V -> [{V, Pid} | Acc]
                             end
                     end, [], erlang:processes()),
            Top = lists:sublist(lists:reverse(lists:sort(Vals)), N),
            {builtin, [proc_entry(Pid, V, proc_info(Pid)) || {V, Pid} <- Top]}
    end.

proc_attr(Pid, binary_memory) ->
    case erlang:process_info(Pid, binary) of
        {binary, Bins} -> lists:sum([Size || {_, Size, _} <- Bins]);
        undefined -> undefined
    end;
proc_attr(Pid, Attr) ->
    case erlang:process_info(Pid, Attr) of
        {Attr, V} -> V;
        undefined -> undefined
    end.

proc_info(Pid) ->
    case erlang:process_info(Pid, [registered_name, current_function, initial_call]) of
        undefined -> [];
        Props -> Props
    end.

%% recon's info list is [Name | Props] for registered processes, else Props.
proc_entry(Pid, Val, Info) ->
    {Name, Props} = case Info of
                        [N | Rest] when is_atom(N) -> {N, Rest};
                        _ -> {proplists:get_value(registered_name, Info, []), Info}
                    end,
    Initial = proplists:get_value(initial_call, Props),
    #{pid => Pid,
      value => Val,
      name => registered_name(Name),
      current_function => proplists:get_value(current_function, Props),
      initial_call => initial_call(Pid, Initial, [])}.

%% Garbage collects every process; memory before and after.
gc_all() ->
    Before = maps:from_list(erlang:memory()),
    _ = [erlang:garbage_collect(P) || P <- erlang:processes()],
    After = maps:from_list(erlang:memory()),
    #{before => Before, 'after' => After}.

%% Which processes hold references to binaries they no longer use: every
%% process is garbage collected and the ones whose binary references drop
%% the most are returned (recon:bin_leak/1). Also binary memory before
%% and after.
binary_leaks(N) ->
    BinBefore = erlang:memory(binary),
    {Source, Procs} =
        case recon_available() of
            true ->
                {recon, [proc_entry(Pid, -Delta, Info) || {Pid, Delta, Info} <- recon:bin_leak(N)]};
            false ->
                Before = [{P, bin_count(P)} || P <- erlang:processes()],
                _ = [erlang:garbage_collect(P) || {P, _} <- Before],
                Deltas = [{B - A, P} || {P, B} <- Before, B =/= undefined,
                                         (A = bin_count(P)) =/= undefined],
                Top = lists:sublist(lists:reverse(lists:sort(Deltas)), N),
                {builtin, [proc_entry(P, D, proc_info(P)) || {D, P} <- Top]}
        end,
    #{source => Source,
      binary_before => BinBefore,
      binary_after => erlang:memory(binary),
      %% value: binary references released by the collection
      processes => Procs}.

bin_count(Pid) ->
    case erlang:process_info(Pid, binary) of
        {binary, Bins} -> length(Bins);
        undefined -> undefined
    end.

%% Every ETS table, as ets:i() lists them, with memory in bytes.
ets_tables() ->
    Word = erlang:system_info(wordsize),
    lists:filtermap(
      fun(T) ->
              case ets:info(T) of
                  undefined ->
                      false;
                  Info ->
                      Owner = proplists:get_value(owner, Info),
                      {true, #{id => T,
                               name => proplists:get_value(name, Info),
                               named => proplists:get_value(named_table, Info),
                               type => proplists:get_value(type, Info),
                               protection => proplists:get_value(protection, Info),
                               size => proplists:get_value(size, Info),
                               memory => proplists:get_value(memory, Info) * Word,
                               owner => Owner,
                               owner_name => registered_name(
                                                element(2, owner_name(Owner)))}}
              end
      end, ets:all()).

owner_name(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, _} = R -> R;
        _ -> {registered_name, []}
    end.

%% What a process is doing and holding: its stack and, for OTP processes,
%% sys:get_status/2 (that messages the process, so only on request).
process_state(Pid, WithStatus) when is_pid(Pid) ->
    case erlang:process_info(Pid, [current_stacktrace, message_queue_len, memory,
                                   total_heap_size, registered_name]) of
        undefined ->
            undefined;
        Info ->
            Status = case WithStatus of
                         true ->
                             try sys:get_status(Pid, 2000) of
                                 S -> {ok, S}
                             catch
                                 exit:{timeout, _} -> {error, timeout};
                                 exit:{noproc, _} -> {error, noproc};
                                 C:R -> {error, {C, R}}
                             end;
                         false ->
                             not_requested
                     end,
            #{stack => proplists:get_value(current_stacktrace, Info),
              message_queue_len => proplists:get_value(message_queue_len, Info),
              memory => proplists:get_value(memory, Info),
              name => registered_name(proplists:get_value(registered_name, Info)),
              status => Status}
    end.

%%% ============================================================================
%%% OTP process state and supervision trees
%%% ============================================================================

-define(SYS_STATE_TIMEOUT, 3000).
-define(TREE_MAX_DEPTH, 12).
-define(TREE_MAX_NODES, 2000).

%% {ok, CallbackModule, State, RecordDefs} | {error, Reason}.
%% sys:get_state/2 (the process answers a system message, so a busy
%% process times out). RecordDefs are the callback module's records
%% ([{Name, [Field]}], when it has debug info), for naming them.
get_state(Pid) when is_pid(Pid) ->
    try sys:get_state(Pid, ?SYS_STATE_TIMEOUT) of
        State ->
            Mod = callback_module(Pid),
            {ok, Mod, State, module_records(Mod)}
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, noproc};
        Class:Reason -> {error, {Class, Reason}}
    end.

callback_module(Pid) ->
    case erlang:process_info(Pid, initial_call) of
        {initial_call, IC} ->
            case initial_call(Pid, IC, []) of
                %% not started through proc_lib: no callback module known
                {M, _, _} when M =/= proc_lib, M =/= erlang -> M;
                _ -> undefined
            end;
        undefined ->
            undefined
    end.

module_records(undefined) -> [];
module_records(Mod) ->
    try erlyberly:load_module_records(Mod) of
        {ok, Recs} -> Recs;
        _ -> []
    catch
        _:_ -> []
    end.

%% The supervision tree under Sup: nested maps
%% #{pid, id, type => supervisor | worker, name, kind, modules, memory,
%%   message_queue_len, strategy, children => [...] | more | {error, R}}.
%% Children are asked for with a timeout (a supervisor busy restarting
%% does not hang this); depth and size are capped.
supervision_tree(Sup) when is_pid(Sup) ->
    {Tree, _Count} = sup_node(Sup, root, [], 0, 0),
    Tree.

sup_node(Pid, Id, Modules, Depth, Count) ->
    Base = (proc_node(Pid))#{id => Id, type => supervisor, modules => Modules,
                             strategy => strategy(Pid)},
    if
        Depth >= ?TREE_MAX_DEPTH; Count >= ?TREE_MAX_NODES ->
            {Base#{children => more}, Count + 1};
        true ->
            case catch gen_server:call(Pid, which_children, ?SYS_STATE_TIMEOUT) of
                Kids when is_list(Kids) ->
                    {Children, Count1} =
                        lists:mapfoldl(fun(K, C) -> child_node(K, Depth, C) end,
                                       Count + 1, Kids),
                    {Base#{children => Children}, Count1};
                {'EXIT', {Reason, _}} ->
                    {Base#{children => {error, short_reason(Reason)}}, Count + 1};
                Other ->
                    {Base#{children => {error, Other}}, Count + 1}
            end
    end.

child_node({Id, Child, supervisor, Mods}, Depth, Count) when is_pid(Child) ->
    sup_node(Child, Id, mods(Mods), Depth + 1, Count);
child_node({Id, Child, Type, Mods}, _Depth, Count) when is_pid(Child) ->
    {(proc_node(Child))#{id => Id, type => Type, modules => mods(Mods), children => []},
     Count + 1};
child_node({Id, NotRunning, Type, Mods}, _Depth, Count) ->
    %% restarting | undefined (not running)
    {#{pid => NotRunning, id => Id, type => Type, modules => mods(Mods), name => nil,
       kind => nil, memory => 0, message_queue_len => 0, children => []},
     Count + 1}.

mods(dynamic) -> dynamic;
mods(L) when is_list(L) -> L;
mods(_) -> [].

proc_node(Pid) ->
    case erlang:process_info(Pid, [registered_name, initial_call, current_function,
                                   memory, message_queue_len]) of
        undefined ->
            #{pid => Pid, name => nil, kind => nil, memory => 0, message_queue_len => 0};
        Props ->
            IC = initial_call(Pid, proplists:get_value(initial_call, Props), Props),
            {Kind, _} = kind(IC, proplists:get_value(current_function, Props), #{}),
            #{pid => Pid,
              name => registered_name(proplists:get_value(registered_name, Props)),
              kind => Kind,
              memory => proplists:get_value(memory, Props),
              message_queue_len => proplists:get_value(message_queue_len, Props)}
    end.

%% one_for_one etc., from the supervisor's state record when it is the
%% familiar #state{name, strategy, ...} (OTP's supervisor); nil otherwise.
strategy(Pid) ->
    try sys:get_state(Pid, ?SYS_STATE_TIMEOUT) of
        S when is_tuple(S), tuple_size(S) > 3, element(1, S) =:= state ->
            case element(3, S) of
                St when St =:= one_for_one; St =:= one_for_all;
                        St =:= rest_for_one; St =:= simple_one_for_one -> St;
                _ -> nil
            end;
        _ -> nil
    catch
        _:_ -> nil
    end.

short_reason({timeout, _}) -> timeout;
short_reason(timeout) -> timeout;
short_reason(R) -> R.

%%% GC investigation: cheap process samples; tracing is opt-in and bounded.
gc_snapshot() ->
    Word = erlang:system_info(wordsize),
    Keys0 = [registered_name, initial_call, current_function, memory,
             total_heap_size, stack_size, message_queue_len, status,
             garbage_collection, garbage_collection_info],
    Keys = case dict_key_supported() of
               true -> Keys0 ++ [?INITIAL_CALL_KEY];
               false -> Keys0
           end,
    {Rows, _Cache} = lists:foldl(fun(Pid, {Acc, Cache}) ->
        case erlang:process_info(Pid, Keys) of
            undefined -> {Acc, Cache};
            Props ->
                G = proplists:get_value(garbage_collection, Props),
                I = proplists:get_value(garbage_collection_info, Props),
                InitialCall = initial_call(Pid, proplists:get_value(initial_call, Props), Props),
                Current = proplists:get_value(current_function, Props),
                {Kind, Cache1} = kind(InitialCall, Current, Cache),
                {[#{pid => Pid,
                    name => registered_name(proplists:get_value(registered_name, Props)),
                    initial_call => InitialCall,
                    current_function => Current,
                    kind => Kind,
                    memory => proplists:get_value(memory, Props),
                    total_heap => proplists:get_value(total_heap_size, Props) * Word,
                    stack => proplists:get_value(stack_size, Props) * Word,
                    queued => proplists:get_value(message_queue_len, Props),
                    status => proplists:get_value(status, Props),
                    gc => gc_info(G, I, Word)} | Acc], Cache1}
        end
    end, {[], #{}}, erlang:processes()),
    {Count, Reclaimed, _} = erlang:statistics(garbage_collection),
    #{sampled_at_ms => erlang:monotonic_time(millisecond),
      collections => Count, reclaimed_bytes => Reclaimed * Word,
      processes => lists:reverse(Rows)}.

%% Each collector owns only its selected process's GC flag. It exits after
%% 30 s or 200 collections, on owner/tracee death, or if its queue overloads.
%% A dying tracer automatically loses its trace flags (also on node loss).
gc_trace_start(Pid, Owner, Seconds)
  when is_pid(Pid), node(Pid) =:= node(), is_pid(Owner),
       is_integer(Seconds), Seconds >= 1, Seconds =< 30 ->
    case erlang:trace_info(Pid, tracer) of
        {tracer, []} ->
            Parent = self(), Ref = make_ref(),
            Collector = spawn(fun() -> gc_trace_init(Parent, Ref, Pid, Owner, Seconds) end),
            receive
                {Ref, Result} -> Result
            after 1000 -> exit(Collector, kill), {error, start_timeout}
            end;
        undefined -> {error, process_exited};
        _ -> {error, already_traced}
    end.

gc_trace_init(Parent, Ref, Pid, Owner, Seconds) ->
    erlang:monitor(process, Owner),
    erlang:monitor(process, Pid),
    try erlang:trace(Pid, true, [garbage_collection, monotonic_timestamp, {tracer, self()}]) of
        1 ->
            Parent ! {Ref, {ok, self()}},
            erlang:send_after(Seconds * 1000, self(), stop),
            gc_trace_loop(Pid, Owner, undefined, 0);
        _ -> Parent ! {Ref, {error, process_exited}}
    catch error:badarg -> Parent ! {Ref, {error, already_traced}}
    end.

gc_trace_loop(Pid, Owner, Start, Count) ->
    {message_queue_len, Queue} = erlang:process_info(self(), message_queue_len),
    case Queue > 1000 orelse Count >= 200 of
        true -> Owner ! {gc_trace_done, self(), limit};
        false ->
            receive
                {trace_ts, Pid, Kind, Info, At}
                  when Kind =:= gc_minor_start; Kind =:= gc_major_start ->
                    gc_trace_loop(Pid, Owner, {Kind, Info, At}, Count);
                {trace_ts, Pid, Kind, Info, At}
                  when Kind =:= gc_minor_end; Kind =:= gc_major_end ->
                    case Start of
                        {StartKind, Before, Since}
                          when (StartKind =:= gc_minor_start andalso Kind =:= gc_minor_end)
                            orelse (StartKind =:= gc_major_start andalso Kind =:= gc_major_end) ->
                            Word = erlang:system_info(wordsize),
                            Heap = fun(L) -> (proplists:get_value(heap_size, L, 0) +
                                             proplists:get_value(old_heap_size, L, 0)) * Word end,
                            Event = #{kind => case Kind of gc_minor_end -> minor; _ -> major end,
                                duration_us => erlang:convert_time_unit(At - Since, native, microsecond),
                                before => Heap(Before), 'after' => Heap(Info)},
                            Owner ! {gc_trace_event, self(), Event};
                        _ -> ok
                    end,
                    gc_trace_loop(Pid, Owner, undefined, Count + 1);
                stop -> Owner ! {gc_trace_done, self(), stopped};
                {'DOWN', _, process, _, _} -> Owner ! {gc_trace_done, self(), process_down};
                _ -> gc_trace_loop(Pid, Owner, Start, Count)
            end
    end.
