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
    Existing = maps:from_list([{Pid, true} || Pid <- erlang:processes(), idle_at_boundary(Pid)]),
    Session = trace:session_create(beamdash_cpu, self(), []),
    try
        trace:process(Session, all, true, [running, monotonic_timestamp]),
        Start = erlang:monotonic_time(nanosecond),
        case collect(Session, Start, Start + ?SAMPLE_NS, #{}, #{}, 0) of
            {ok, Values} ->
                Idle = maps:from_list([{Pid, 0.0} || Pid <- erlang:processes(),
                                                    maps:is_key(Pid, Existing), idle_at_boundary(Pid)]),
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
        {status, runnable} -> true;
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
                   collect(Session, Start, End, maps:put(Pid, max(Start, Ts), Running), Totals, Count + 1);
               {trace_ts, Pid, out, _, Ts} ->
                   {NextRunning, NextTotals} = add_time(Pid, Ts, End, Running, Totals),
                   collect(Session, Start, End, NextRunning, NextTotals, Count + 1)
           after 5 -> collect(Session, Start, End, Running, Totals, Count)
           end
    end.

drain(Start, End, Ref, Running, Totals, Count) when Count < ?MAX_EVENTS ->
    receive
        {trace_ts, Pid, in, _, Ts} ->
            drain(Start, End, Ref, maps:put(Pid, max(Start, Ts), Running), Totals, Count + 1);
        {trace_ts, Pid, out, _, Ts} ->
            {NextRunning, NextTotals} = add_time(Pid, Ts, End, Running, Totals),
            drain(Start, End, Ref, NextRunning, NextTotals, Count + 1);
        {trace_delivered, all, Ref} ->
            Final = maps:fold(fun(Pid, Ts, Acc) ->
                maps:update_with(Pid, fun(V) -> V + max(0, End - Ts) end, max(0, End - Ts), Acc)
            end, Totals, Running),
            {ok, maps:map(fun(_, Ns) -> min(100.0, Ns * 100.0 / (End - Start)) end, Final)}
    after 1000 -> {error, timeout}
    end;
drain(_, _, _, _, _, _) -> {error, overloaded}.

add_time(Pid, Ts, End, Running, Totals) ->
    case maps:take(Pid, Running) of
        {From, NextRunning} ->
            Elapsed = max(0, min(Ts, End) - From),
            {NextRunning, maps:update_with(Pid, fun(V) -> V + Elapsed end, Elapsed, Totals)};
        error -> {Running, Totals}
    end.
