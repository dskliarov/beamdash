%%% Short, isolated scheduler-time sample. OTP 27+ trace sessions do not
%%% change the node's legacy trace settings used by other tools.
-module(beamdash_cpu).
-export([sample/0]).

-define(SAMPLE_NS, 250000000).
-define(MAX_EVENTS, 50000).
-define(MAX_QUEUE, 10000).

sample() ->
    case code:ensure_loaded(trace) =:= {module, trace} andalso
         erlang:function_exported(trace, session_create, 3) of
        true ->
            Caller = self(),
            {Pid, Monitor} = spawn_monitor(fun() -> Caller ! {self(), measure()} end),
            receive
                {Pid, Result} -> demonitor(Monitor, [flush]), Result;
                {'DOWN', Monitor, process, Pid, Reason} -> {error, {sample_failed, Reason}}
            after 2000 ->
                exit(Pid, kill), demonitor(Monitor, [flush]), {error, timeout}
            end;
        false -> {error, unsupported_otp}
    end.

measure() ->
    case try register(beamdash_cpu_sampler, self()) catch error:badarg -> false end of
        true -> measure_registered();
        _ -> {error, busy}
    end.

measure_registered() ->
    Session = trace:session_create(beamdash_cpu, self(), []),
    try
        trace:process(Session, all, true, [running, monotonic_timestamp]),
        Pids = erlang:processes(),
        Existing = maps:from_list([{Pid, true} || Pid <- Pids, idle_at_boundary(Pid)]),
        Unknown = maps:from_list([{Pid, unknown} || Pid <- Pids, not maps:is_key(Pid, Existing)]),
        %% Observe a short lead-in so normal scheduler switches establish
        %% which processes were already running at the sample boundary.
        receive after 10 -> ok end,
        Start = erlang:monotonic_time(nanosecond),
        case collect(Session, Start, Start + ?SAMPLE_NS, #{}, Unknown, 0) of
            {ok, Values, Missing} ->
                Idle = maps:from_list([{Pid, 0.0} || Pid <- erlang:processes(),
                                                    maps:is_key(Pid, Existing),
                                                    not maps:is_key(Pid, Missing),
                                                    idle_at_boundary(Pid)]),
                {ok, maps:merge(Idle, Values)};
            Error -> Error
        end
    catch Class:Reason -> {error, {Class, Reason}}
    after trace:session_destroy(Session)
    end.

%% A process already running at a boundary may stay inside native code for
%% the entire window without producing an in/out pair. Its time is unknown.
idle_at_boundary(Pid) ->
    case process_info(Pid, status) of
        {status, waiting} -> true;
        {status, suspended} -> true;
        _ -> false
    end.

collect(Session, Start, End, Running, Totals, Count) ->
    Now = erlang:monotonic_time(nanosecond),
    {message_queue_len, Queue} = process_info(self(), message_queue_len),
    if Count >= ?MAX_EVENTS orelse Queue >= ?MAX_QUEUE ->
           {error, overloaded};
       Now >= End ->
           trace:process(Session, all, false, [running]),
           Ref = trace:delivered(Session, all),
           drain(Start, End, Ref, Running, Totals, Count);
       true ->
           receive
               {trace_ts, Pid, in, _, Ts} ->
                   {NextRunning, NextTotals} = record_in(Pid, Ts, Start, Running, Totals),
                   collect(Session, Start, End, NextRunning, NextTotals, Count + 1);
               {trace_ts, Pid, out, _, Ts} ->
                   {NextRunning, NextTotals} = record_out(Pid, Ts, Start, End, Running, Totals),
                   collect(Session, Start, End, NextRunning, NextTotals, Count + 1)
           after 5 -> collect(Session, Start, End, Running, Totals, Count)
           end
    end.

drain(Start, End, Ref, Running, Totals, Count) when Count < ?MAX_EVENTS ->
    receive
        {trace_ts, Pid, in, _, Ts} ->
            {NextRunning, NextTotals} = record_in(Pid, Ts, Start, Running, Totals),
            drain(Start, End, Ref, NextRunning, NextTotals, Count + 1);
        {trace_ts, Pid, out, _, Ts} ->
            {NextRunning, NextTotals} = record_out(Pid, Ts, Start, End, Running, Totals),
            drain(Start, End, Ref, NextRunning, NextTotals, Count + 1);
        {trace_delivered, all, Ref} ->
            Final = maps:fold(fun(Pid, Ts, Acc) ->
                add_total(Pid, max(0, End - Ts), Acc)
            end, Totals, Running),
            {Values, Missing} = maps:fold(fun(Pid, unknown, {V, M}) ->
                                                {V, maps:put(Pid, true, M)};
                                             (Pid, Ns, {V, M}) ->
                                                {maps:put(Pid, min(100.0, Ns * 100.0 / (End - Start)), V), M}
                                          end, {#{}, #{}}, Final),
            {ok, Values, Missing}
    after 1000 -> {error, timeout}
    end;
drain(_, _, _, _, _, _) -> {error, overloaded}.

record_in(Pid, Ts, Start, Running, Totals) when Ts =< Start ->
    {maps:put(Pid, Start, Running), maps:remove(Pid, Totals)};
record_in(Pid, Ts, _Start, Running, Totals) ->
    {maps:put(Pid, Ts, Running), Totals}.

record_out(Pid, Ts, Start, _End, Running, Totals) when Ts =< Start ->
    {maps:remove(Pid, Running), maps:remove(Pid, Totals)};
record_out(Pid, Ts, _Start, End, Running, Totals) ->
    add_time(Pid, Ts, End, Running, Totals).

add_time(Pid, Ts, End, Running, Totals) ->
    case maps:take(Pid, Running) of
        {From, NextRunning} ->
            Elapsed = max(0, min(Ts, End) - From),
            {NextRunning, add_total(Pid, Elapsed, Totals)};
        error -> {Running, maps:put(Pid, unknown, Totals)}
    end.

add_total(Pid, Elapsed, Totals) ->
    maps:update_with(Pid, fun(unknown) -> unknown; (V) -> V + Elapsed end, Elapsed, Totals).
