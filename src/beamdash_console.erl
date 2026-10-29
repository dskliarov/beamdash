%%% Per-page remote evaluator. Only kernel/stdlib are required for Erlang mode.
-module(beamdash_console).
-export([start/2, eval/2, eval/3, submit/3]).

start(Owner, Language) when is_pid(Owner), (Language =:= erlang orelse Language =:= elixir) ->
    {ok, spawn(fun() ->
        process_flag(trap_exit, true),
        OwnerRef = monitor(process, Owner),
        {Worker, WorkerRef} = worker_start(Language),
        loop(OwnerRef, Language, Worker, WorkerRef, none)
    end)}.

eval(Session, Code) -> eval(Session, Code, 5000).
eval(Session, Code, Timeout) when is_pid(Session), is_binary(Code), byte_size(Code) =< 32768,
                                  is_integer(Timeout), Timeout >= 100, Timeout =< 60000 ->
    request(Session, Code, Timeout).

submit(Session, Code, Timeout) when is_pid(Session), is_binary(Code), byte_size(Code) =< 32768,
                                    is_integer(Timeout), Timeout >= 100, Timeout =< 60000 ->
    request(Session, {repl, Code}, Timeout).

request(Session, Code, Timeout) ->
    Ref = make_ref(),
    Monitor = monitor(process, Session),
    Session ! {eval, self(), Ref, Code, Timeout},
    receive
        {Ref, Result} -> demonitor(Monitor, [flush]), Result;
        {'DOWN', Monitor, process, _, Reason} -> result(error, format({session_closed, Reason}), <<>>)
    after Timeout + 1000 -> demonitor(Monitor, [flush]), result(error, <<"Console session did not respond. Reset the session.">>, <<>>)
    end.

worker_start(Language) ->
    Controller = self(),
    spawn_opt(fun() -> group_leader(Controller, self()), worker(Controller, Language, []) end, [link, monitor]).

worker(Controller, Language, Bindings) ->
    receive
        {eval, Ref, Code} ->
            Result = try
                case prepare(Language, Code) of
                    incomplete -> {incomplete, <<>>, Bindings};
                    {ready, Source} ->
                        {Value, NextBindings} = evaluate(Language, Source, Bindings),
                        {ok, format_value(Language, Value), NextBindings}
                end
            catch Kind:Reason -> {error, format({Kind, Reason}), Bindings}
            end,
            {Status, Text, Next} = Result,
            Controller ! {evaluated, Ref, Status, Text},
            worker(Controller, Language, Next)
    end.

prepare(erlang, {repl, Code}) ->
    % erl_scan handles periods inside strings/comments and waits for a real terminator.
    case erl_scan:tokens([], unicode:characters_to_list(Code) ++ "\n", 1) of
        {more, _} -> incomplete;
        _ -> {ready, Code}
    end;
prepare(elixir, {repl, Code}) ->
    try 'Elixir.Code':'string_to_quoted!'(Code) of
        _ -> {ready, Code}
    catch error:#{'__struct__' := 'Elixir.TokenMissingError'} -> incomplete
    end;
prepare(_, Code) -> {ready, Code}.

evaluate(erlang, Code, Bindings) ->
    Text = string:trim(unicode:characters_to_list(Code)),
    Source = case lists:reverse(Text) of [$. | _] -> Text; _ -> Text ++ "." end,
    {ok, Tokens, _} = erl_scan:string(Source),
    {ok, Expressions} = erl_parse:parse_exprs(Tokens),
    {value, Value, Next} = erl_eval:exprs(Expressions, Bindings),
    {Value, Next};
evaluate(elixir, Code, []) ->
    evaluate(elixir, Code, {[], 'Elixir.Code':env_for_eval([])});
evaluate(elixir, Code, {Bindings, Env}) ->
    Quoted = 'Elixir.Code':'string_to_quoted!'(Code),
    {Value, Next, NextEnv} = 'Elixir.Code':eval_quoted_with_env(Quoted, Bindings, Env),
    {Value, {Next, NextEnv}}.

format_value(elixir, Value) ->
    limit('Elixir.Kernel':inspect(Value, [{limit, 50}, {printable_limit, 4000}]), 8000);
format_value(erlang, Value) -> format(Value).
format(Value) -> limit(unicode:characters_to_binary(io_lib:format("~tP", [Value, 20], [{chars_limit, 4000}])), 8000).
result(Status, Value, Output) -> #{status => Status, result => Value, output => Output}.

loop(OwnerRef, Language, Worker, WorkerRef, Pending) ->
    receive
        {eval, From, Ref, Code, Timeout} when Pending =:= none ->
            Timer = erlang:send_after(Timeout, self(), {timeout, Ref}),
            Worker ! {eval, Ref, Code},
            loop(OwnerRef, Language, Worker, WorkerRef, {From, Ref, Timer, <<>>});
        {eval, From, Ref, _, _} ->
            From ! {Ref, result(error, <<"Console is busy.">>, <<>>)},
            loop(OwnerRef, Language, Worker, WorkerRef, Pending);
        {evaluated, Ref, Status, Value} when Pending =/= none, element(2, Pending) =:= Ref ->
            {From, Ref, Timer, Output} = Pending,
            erlang:cancel_timer(Timer),
            From ! {Ref, result(Status, Value, Output)},
            loop(OwnerRef, Language, Worker, WorkerRef, none);
        {timeout, Ref} when Pending =/= none, element(2, Pending) =:= Ref ->
            {From, Ref, _, Output} = Pending,
            exit(Worker, kill), demonitor(WorkerRef, [flush]),
            From ! {Ref, result(error, <<"Evaluation timed out; bindings were reset. Side effects are not undone.">>, Output)},
            {Next, NextRef} = worker_start(Language),
            loop(OwnerRef, Language, Next, NextRef, none);
        {'DOWN', OwnerRef, process, _, _} -> exit(Worker, kill);
        {'DOWN', WorkerRef, process, _, Reason} ->
            case Pending of
                {From, Ref, Timer, Output} ->
                    erlang:cancel_timer(Timer),
                    From ! {Ref, result(error, format({evaluator_exited, Reason}), Output)};
                none -> ok
            end,
            {Next, NextRef} = worker_start(Language),
            loop(OwnerRef, Language, Next, NextRef, none);
        {io_request, From, ReplyAs, Request} ->
            {Reply, Text} = io_request(Request),
            From ! {io_reply, ReplyAs, Reply},
            NextPending = case Pending of
                {Caller, Ref, Timer, Output} -> {Caller, Ref, Timer, limit(<<Output/binary, Text/binary>>, 64000)};
                none -> none
            end,
            loop(OwnerRef, Language, Worker, WorkerRef, NextPending);
        stop -> exit(Worker, kill);
        _ -> loop(OwnerRef, Language, Worker, WorkerRef, Pending)
    end.

io_request({put_chars, _Encoding, Chars}) -> chars(Chars);
io_request({put_chars, Chars}) -> chars(Chars);
io_request({put_chars, _Encoding, Module, Function, Args}) ->
    try chars(apply(Module, Function, Args)) catch _:_ -> {{error, badarg}, <<>>} end;
io_request({put_chars, Module, Function, Args}) -> io_request({put_chars, unicode, Module, Function, Args});
io_request({requests, Requests}) ->
    lists:foldl(fun(Request, {_, Acc}) ->
        {Reply, Text} = io_request(Request),
        {Reply, limit(<<Acc/binary, Text/binary>>, 64000)}
    end, {ok, <<>>}, Requests);
io_request(getopts) -> {{ok, [{encoding, unicode}]}, <<>>};
io_request({setopts, _}) -> {ok, <<>>};
io_request(_) -> {{error, enotsup}, <<>>}.
chars(Chars) ->
    try {ok, limit(unicode:characters_to_binary(Chars), 64000)} catch _:_ -> {{error, badarg}, <<>>} end.
limit(Bin, Size) when byte_size(Bin) =< Size -> Bin;
limit(Bin, Size) ->
    Prefix = binary:part(Bin, 0, Size),
    case unicode:characters_to_binary(Prefix) of
        Good when is_binary(Good) -> Good;
        {_, Good, _} -> Good
    end.
