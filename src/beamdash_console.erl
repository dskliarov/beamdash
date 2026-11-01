%%% Per-page remote evaluator. Only kernel/stdlib are required for Erlang mode.
-module(beamdash_console).
-export([start/2, eval/2, eval/3, submit/3, set_input/3, release_input/2, release_frame/2]).

start(Owner, Language) when is_pid(Owner), (Language =:= erlang orelse Language =:= elixir) ->
    {ok, spawn(fun() ->
        process_flag(trap_exit, true),
        put(beamdash_owner, Owner),
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

set_input(Session, Id, Value) when is_pid(Session), is_binary(Id), is_binary(Value), byte_size(Value) =< 4096 ->
    Ref = make_ref(),
    Session ! {set_input, self(), Ref, Id, Value},
    receive {Ref, Reply} -> Reply after 1000 -> {error, timeout} end.

release_input(Session, Id) when is_pid(Session), is_binary(Id), byte_size(Id) =< 256 ->
    Ref = make_ref(),
    Session ! {release_input, self(), Ref, Id},
    receive {Ref, Reply} -> Reply after 1000 -> {error, timeout} end.

release_frame(Session, Id) when is_pid(Session), is_binary(Id), byte_size(Id) =< 256 ->
    Ref = make_ref(),
    Session ! {release_frame, self(), Ref, Id},
    receive {Ref, Reply} -> Reply after 1000 -> {error, timeout} end.

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
                        {ok, format_value(Language, Value), NextBindings, widget(Language, Value)}
                end
            catch Kind:Reason:Stack -> {error, evaluation_error(Kind, Reason, Stack), Bindings, none}
            end,
            {Status, Text, Next, Widget} = case Result of
                {incomplete, Text0, Bindings0} -> {incomplete, Text0, Bindings0, none};
                Other -> Other
            end,
            Controller ! {evaluated, Ref, Status, Text, Widget},
            worker(Controller, Language, Next)
    end.

evaluation_error(error, undef, [{Module, Function, Arguments, _} | _])
  when is_atom(Module), is_atom(Function) ->
    Arity = case Arguments of N when is_integer(N) -> N; Args when is_list(Args) -> length(Args) end,
    Name = atom_to_binary(Module, utf8),
    IsKino = case Name of <<"Elixir.Kino.", _/binary>> -> true; <<"Elixir.Kino">> -> true; _ -> false end,
    case IsKino andalso code:which(Module) =:= non_existing of
        true ->
            <<"Kino is not available on the connected node (missing ",
              (binary:part(Name, 7, byte_size(Name) - 7))/binary, ".",
              (atom_to_binary(Function, utf8))/binary, "/", (integer_to_binary(Arity))/binary,
              "). Install and start Kino as part of the target application, or connect to an Elixir node where Kino is installed and running.">>;
        false ->
            limit(unicode:characters_to_binary(io_lib:format("Undefined function ~ts:~ts/~B on the connected node.", [Name, atom_to_binary(Function, utf8), Arity])), 8000)
    end;
evaluation_error(Kind, Reason, _) -> format({Kind, Reason}).

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
format_value(erlang, Value) ->
    limit(unicode:characters_to_binary(io_lib:format("~60tP", [Value, 20], [{chars_limit, 4000}])), 8000).
format(Value) -> limit(unicode:characters_to_binary(io_lib:format("~tP", [Value, 20], [{chars_limit, 4000}])), 8000).
result(Status, Value, Output) -> #{status => Status, result => Value, output => Output}.

%% Only these built-in widgets are exposed. References stay in the session.
widget(elixir, #{'__struct__' := 'Elixir.Kino.Layout', type := Type, items := Items, info := Info})
  when (Type =:= grid orelse Type =:= tabs), is_list(Items), length(Items) =< 50, is_map(Info) ->
    try
        Outputs = ['Elixir.Kino.Render':to_livebook(Item) || Item <- Items],
        case {frame_outputs(Outputs), layout_options(Type, Info, length(Items))} of
            {{ok, Rendered}, {ok, Options}} ->
                Id = <<"layout:", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
                {maps:merge(#{type => layout, id => Id, layout => Type, items => Rendered, active => 0}, Options), undefined, undefined};
            _ -> none
        end
    catch _:_ -> none end;
widget(elixir, #{'__struct__' := 'Elixir.Kino.Frame', ref := Ref, pid := Pid})
  when is_binary(Ref), byte_size(Ref) =< 256, is_pid(Pid) ->
    try gen_server:call(Pid, get_items, 1000) of
        Items when is_list(Items), length(Items) =< 50 ->
            Outputs = ['Elixir.Kino.Render':to_livebook(Item) || Item <- Items],
            case frame_outputs(Outputs) of
                {ok, Rendered} -> {#{type => frame, id => Ref, items => Rendered}, undefined, undefined};
                error -> none
            end;
        _ -> none
    catch _:_ -> none end;
widget(elixir, #{'__struct__' := 'Elixir.Kino.JS.Live', module := 'Elixir.Kino.VegaLite', ref := Ref, pid := Pid})
  when is_binary(Ref), byte_size(Ref) =< 256, is_pid(Pid) ->
    {#{type => live_chart, id => Ref}, Pid, undefined};
widget(elixir, #{'__struct__' := 'Elixir.Kino.JS', module := 'Elixir.Kino.VegaLite', ref := Ref})
  when is_binary(Ref), byte_size(Ref) =< 256 ->
    case whereis('Elixir.Kino.JS.DataStore') of
        Pid when is_pid(Pid) ->
            Pid ! {connect, self(), #{origin => <<"beamdash">>, ref => Ref}},
            receive
                {connect_reply, #{spec := Spec}, #{ref := Ref}} ->
                    widget(elixir, #{'__struct__' => 'Elixir.VegaLite', spec => Spec})
            after 1000 -> none
            end;
        _ -> none
    end;
widget(elixir, #{'__struct__' := 'Elixir.VegaLite', spec := Spec}) when is_map(Spec) ->
    case byte_size(term_to_binary(Spec)) =< 1048576 of
        true -> {#{type => chart, spec => Spec}, undefined, undefined};
        false -> none
    end;
widget(elixir, #{'__struct__' := 'Elixir.Kino.Markdown', text := Text})
  when is_binary(Text), byte_size(Text) =< 16000 ->
    {#{type => markdown, text => Text}, undefined, undefined};
widget(elixir, #{'__struct__' := 'Elixir.Kino.Text', text := Text})
  when is_binary(Text), byte_size(Text) =< 16000 ->
    {#{type => plain_text, text => Text}, undefined, undefined};
widget(elixir, #{'__struct__' := 'Elixir.Kino.Image', content := Content, mime_type := Mime})
  when is_binary(Content), byte_size(Content) =< 1048576,
       (Mime =:= <<"image/png">> orelse Mime =:= <<"image/jpeg">> orelse Mime =:= <<"image/gif">>) ->
    {#{type => image, mime => Mime, data => base64:encode(Content)}, undefined, undefined};
widget(elixir, #{'__struct__' := 'Elixir.Kino.Input', id := Id,
                 attrs := #{type := Type, label := Label, default := Default}} = Input)
  when is_binary(Id), byte_size(Id) =< 256, is_binary(Label), byte_size(Label) =< 4096,
       (((Type =:= text orelse Type =:= textarea orelse Type =:= password orelse Type =:= color)
         andalso is_binary(Default) andalso byte_size(Default) =< 4096)
        orelse (Type =:= checkbox andalso is_boolean(Default))) ->
    case Type =:= color andalso re:run(Default, <<"^#[0-9a-fA-F]{6}$">>, [{capture, none}]) =/= match of
        true -> none;
        false -> {#{type => Type, id => Id, label => Label, value => Default},
                  maps:get(ref, Input, undefined), maps:get(destination, Input, undefined)}
    end;
widget(elixir, #{'__struct__' := 'Elixir.Kino.Input', id := Id,
                 attrs := #{type := Type, label := Label, default := Default} = Attrs} = Input)
  when is_binary(Id), byte_size(Id) =< 256, is_binary(Label), byte_size(Label) =< 4096,
       (Type =:= number orelse Type =:= range), (is_number(Default) orelse Default =:= nil) ->
    {#{type => Type, id => Id, label => Label, value => Default,
       min => maps:get(min, Attrs, nil), max => maps:get(max, Attrs, nil),
       step => maps:get(step, Attrs, nil)},
     maps:get(ref, Input, undefined), maps:get(destination, Input, undefined)};
widget(elixir, #{'__struct__' := 'Elixir.Kino.Input', id := Id,
                 attrs := #{type := url, label := Label, default := Default}} = Input)
  when is_binary(Id), byte_size(Id) =< 256, is_binary(Label), byte_size(Label) =< 4096,
       (Default =:= nil orelse (is_binary(Default) andalso byte_size(Default) =< 4096)) ->
    {#{type => url, id => Id, label => Label, value => Default},
     maps:get(ref, Input, undefined), maps:get(destination, Input, undefined)};
widget(elixir, #{'__struct__' := 'Elixir.Kino.Input', id := Id,
                 attrs := #{type := date, label := Label, default := Default} = Attrs} = Input)
  when is_binary(Id), byte_size(Id) =< 256, is_binary(Label), byte_size(Label) =< 4096 ->
    case {date_iso(Default), date_iso(maps:get(min, Attrs, nil)), date_iso(maps:get(max, Attrs, nil))} of
        {{ok, Value}, {ok, Min}, {ok, Max}} ->
            {#{type => date, id => Id, label => Label, value => Value, min => Min, max => Max},
             maps:get(ref, Input, undefined), maps:get(destination, Input, undefined), Default};
        _ -> none
    end;
widget(elixir, #{'__struct__' := 'Elixir.Kino.Input', id := Id,
                 attrs := #{type := select, label := Label, default := Default, options := Options}} = Input)
  when is_binary(Id), byte_size(Id) =< 256, is_binary(Label), byte_size(Label) =< 4096,
       is_list(Options), length(Options) > 0, length(Options) =< 200 ->
    case select_options(Options, Default, 0, [], undefined) of
        {ok, Labels, Index} ->
            {#{type => select, id => Id, label => Label, value => Index, options => Labels},
             maps:get(ref, Input, undefined), maps:get(destination, Input, undefined), Options};
        error -> none
    end;
widget(elixir, #{'__struct__' := 'Elixir.Kino.Control', ref := Ref, destination := Dest,
                 attrs := #{type := button, label := Label}})
  when is_binary(Ref), byte_size(Ref) =< 256, is_binary(Label), byte_size(Label) =< 4096 ->
    {#{type => button, id => Ref, label => Label, value => <<>>}, Ref, Dest};
widget(_, _) -> none.

select_options([], _, _, Labels, Index) when is_integer(Index) -> {ok, lists:reverse(Labels), Index};
select_options([{Value, Label} | Rest], Default, N, Labels, Index)
  when is_binary(Label), byte_size(Label) =< 4096 ->
    NextIndex = case Index =:= undefined andalso Value =:= Default of true -> N; false -> Index end,
    select_options(Rest, Default, N + 1, [{N, Label} | Labels], NextIndex);
select_options(_, _, _, _, _) -> error.

date_iso(nil) -> {ok, nil};
date_iso(#{'__struct__' := 'Elixir.Date', calendar := 'Elixir.Calendar.ISO'} = Date) ->
    try {ok, 'Elixir.Date':to_iso8601(Date)} catch _:_ -> error end;
date_iso(_) -> error.

layout_options(grid, Info, _) ->
    Columns = maps:get(columns, Info, 1),
    case is_integer(Columns) andalso Columns >= 1 andalso Columns =< 8 of
        true -> {ok, #{columns => Columns}};
        false -> error
    end;
layout_options(tabs, Info, Count) ->
    Labels = maps:get(labels, Info, []),
    case is_list(Labels) andalso length(Labels) =:= Count andalso
         lists:all(fun(Label) -> is_binary(Label) andalso byte_size(Label) =< 256 end, Labels) of
        true -> {ok, #{labels => Labels}};
        false -> error
    end.

%% Restrict frame content before transferring it to the browser.
frame_outputs(Outputs) when is_list(Outputs), length(Outputs) =< 50 ->
    case byte_size(term_to_binary(Outputs)) =< 2097152 andalso frame_depth(Outputs, 0) of
        true -> frame_outputs(Outputs, [], 0); false -> error
    end;
frame_outputs(_) -> error.
frame_depth(_, Depth) when Depth > 8 -> false;
frame_depth(Outputs, Depth) when is_list(Outputs), length(Outputs) =< 50 ->
    lists:all(fun(#{type := Type, outputs := Children}) when Type =:= grid; Type =:= tabs; Type =:= frame ->
                      frame_depth(Children, Depth + 1);
                 (_) -> true end, Outputs);
frame_depth(_, _) -> false.
frame_outputs(_, _, Size) when Size > 2097152 -> error;
frame_outputs([], Acc, _) -> {ok, lists:reverse(Acc)};
frame_outputs([#{type := Type, text := Text} | Rest], Acc, Size)
  when (Type =:= plain_text orelse Type =:= terminal_text), is_binary(Text), byte_size(Text) =< 16000,
       Size + byte_size(Text) =< 2097152 ->
    frame_outputs(Rest, [#{type => text, text => Text} | Acc], Size + byte_size(Text));
frame_outputs([#{type := markdown, text := Text} | Rest], Acc, Size)
  when is_binary(Text), byte_size(Text) =< 16000, Size + byte_size(Text) =< 2097152 ->
    frame_outputs(Rest, [#{type => markdown, text => Text} | Acc], Size + byte_size(Text));
frame_outputs([#{type := image, content := Content, mime_type := Mime} | Rest], Acc, Size)
  when is_binary(Content), byte_size(Content) =< 1048576,
       Size + byte_size(Content) =< 2097152,
       (Mime =:= <<"image/png">> orelse Mime =:= <<"image/jpeg">> orelse Mime =:= <<"image/gif">>) ->
    frame_outputs(Rest, [#{type => image, mime => Mime, data => base64:encode(Content)} | Acc], Size + byte_size(Content));
frame_outputs([#{type := Type, outputs := Children} = Output | Rest], Acc, Size)
  when (Type =:= grid orelse Type =:= tabs), is_list(Children), length(Children) =< 50 ->
    Info = case Type of grid -> #{columns => maps:get(columns, Output, 1)};
                             tabs -> #{labels => maps:get(labels, Output, [])} end,
    case {frame_outputs(Children), layout_options(Type, Info, length(Children))} of
        {{ok, Items}, {ok, Options}} ->
            Id = <<"layout:", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
            Layout = maps:merge(#{type => layout, layout => Type, id => Id, items => Items, active => 0}, Options),
            frame_outputs(Rest, [Layout | Acc], Size + byte_size(term_to_binary(Output)));
        _ -> error
    end;
frame_outputs([#{type := frame, ref := Ref, outputs := Children} = Output | Rest], Acc, Size)
  when is_binary(Ref), byte_size(Ref) =< 256, is_list(Children), length(Children) =< 50 ->
    case frame_outputs(Children) of
        {ok, Items} -> frame_outputs(Rest, [#{type => frame, id => Ref, items => Items} | Acc], Size + byte_size(term_to_binary(Output)));
        _ -> error
    end;
frame_outputs([#{type := js, js_view := #{ref := Ref, pid := Pid, assets := #{archive_path := Path}}} = Output | Rest], Acc, Size)
  when is_binary(Ref), byte_size(Ref) =< 256, is_binary(Path) ->
    case binary:match(Path, <<"/Kino_VegaLite/">>) of
        nomatch -> error;
        _ -> frame_outputs(Rest, [{chart, Ref, Pid} | Acc], Size + byte_size(term_to_binary(Output)))
    end;
frame_outputs([#{type := input} = Output | Rest], Acc, Size) ->
    case widget(elixir, Output#{'__struct__' => 'Elixir.Kino.Input'}) of
        {#{type := Type} = Public, Ref, Dest, Extra} when Type =:= date; Type =:= select ->
            Spec = Public#{ref => Ref, destination => Dest, private => Extra},
            frame_outputs(Rest, [{nested, Spec} | Acc], Size + byte_size(term_to_binary(Public)));
        {#{id := _} = Public, Ref, Dest} ->
            Spec = Public#{ref => Ref, destination => Dest},
            frame_outputs(Rest, [{nested, Spec} | Acc], Size + byte_size(term_to_binary(Public)));
        _ -> error
    end;
frame_outputs([#{type := control, ref := Ref, destination := Dest,
                 attrs := #{type := button, label := Label}} | Rest], Acc, Size)
  when is_binary(Ref), byte_size(Ref) =< 256, is_binary(Label), byte_size(Label) =< 4096 ->
    Spec = #{id => Ref, ref => Ref, destination => Dest, type => button, label => Label, value => <<>>},
    frame_outputs(Rest, [{nested, Spec} | Acc], Size + byte_size(Label));
frame_outputs(_, _, _) -> error.

frame_apply(FrameRef, Action, Items) ->
    SafeItems = sanitize_frame_items(Items, [FrameRef]),
    Rendered = [frame_item(Item) || Item <- SafeItems],
    OldCharts = case get({kino_frame_charts, FrameRef}) of undefined -> []; Charts -> Charts end,
    OldChildren = case get({kino_frame_children, FrameRef}) of undefined -> []; Children -> Children end,
    OldIds = case get({kino_frame, FrameRef}) of undefined -> []; Existing -> Existing end,
    OldItems = case get({kino_frame_content, FrameRef}) of undefined -> []; Previous -> Previous end,
    Combined = case Action of append -> OldItems ++ Rendered; replace -> Rendered end,
    Kept = cap_kino_frame(Combined),
    KeepIds = lists:usort(frame_widget_ids(Kept)),
    NewIds = frame_widget_ids(Rendered),
    NewChildren = lists:usort(frame_child_ids(Kept)),
    NewCharts = lists:usort(frame_chart_ids(Kept)),
    put({kino_frame_charts, FrameRef}, NewCharts),
    put({kino_frame_children, FrameRef}, NewChildren),
    put({kino_frame, FrameRef}, KeepIds),
    put({kino_frame_content, FrameRef}, Kept),
    Revision = case get({kino_frame_revision, FrameRef}) of undefined -> 1; R -> R + 1 end,
    put({kino_frame_revision, FrameRef}, Revision),
    [release_unowned(Id) || Id <- lists:usort(OldIds ++ NewIds) -- KeepIds],
    [release_frame_if_unowned(Id) || Id <- lists:usort(OldChildren ++ frame_child_ids(Rendered)) -- NewChildren],
    [release_chart_if_unowned(Id) || Id <- lists:usort(OldCharts ++ frame_chart_ids(Rendered)) -- NewCharts],
    Kept.

%% A frame may be reused, but recursive references would make ownership cyclic.
sanitize_frame_items(Items, Ancestors) ->
    [sanitize_frame_item(Item, Ancestors) || Item <- Items].
sanitize_frame_item(#{type := frame, id := Id, items := Items} = Frame, Ancestors) ->
    case lists:any(fun(Parent) -> frame_reaches(Id, Parent, []) end, Ancestors) of
        true -> #{type => text, text => <<"Recursive Kino frame reference is not supported.">>};
        false -> Frame#{items => sanitize_frame_items(Items, [Id | Ancestors])}
    end;
sanitize_frame_item(#{type := layout, items := Items} = Layout, Ancestors) ->
    Layout#{items => sanitize_frame_items(Items, Ancestors)};
sanitize_frame_item(Item, _) -> Item.
frame_reaches(Id, Id, _) -> true;
frame_reaches(Id, Target, Seen) ->
    case lists:member(Id, Seen) of
        true -> false;
        false ->
            Children = case get({kino_frame_children, Id}) of undefined -> []; C -> C end,
            lists:any(fun(Child) -> frame_reaches(Child, Target, [Id | Seen]) end, Children)
    end.

frame_widget_ids(Items) ->
    lists:flatmap(fun(#{type := interactive, widget := #{id := Id}}) -> [Id];
                     (#{type := layout, items := Children}) -> frame_widget_ids(Children);
                     (_) -> [] end, Items).

frame_chart_ids(Items) ->
    lists:flatmap(fun(#{type := chart, id := Id}) -> [Id];
                     (#{type := layout, items := Children}) -> frame_chart_ids(Children);
                     (_) -> [] end, Items).

frame_child_ids(Items) ->
    lists:flatmap(fun(#{type := frame, id := Id}) -> [Id];
                     (#{type := layout, items := Children}) -> frame_child_ids(Children);
                     (_) -> [] end, Items).

sync_frame_item(#{type := interactive, widget := #{id := Id} = W} = Item, Id, Value) ->
    Item#{widget => W#{value => Value}};
sync_frame_item(#{type := Type, items := Items} = Item, Id, Value) when Type =:= layout; Type =:= frame ->
    Item#{items => [sync_frame_item(Child, Id, Value) || Child <- Items]};
sync_frame_item(Item, _, _) -> Item.

sync_kino_frames(Id, Value) ->
    [put({kino_frame_content, Ref},
         [sync_frame_item(Item, Id, Value) || Item <- Items]) || {{kino_frame_content, Ref}, Items} <- get()],
    ok.

cap_kino_frame(Items) ->
    Last = lists:reverse(lists:sublist(lists:reverse(Items), 50)),
    cap_kino_frame(lists:reverse(Last), [], 0).
cap_kino_frame([], Acc, _) -> Acc;
cap_kino_frame([Item | Rest], Acc, Size) ->
    Bytes = case Item of
        #{type := interactive, widget := W} -> byte_size(term_to_binary(W));
        #{type := Type} when Type =:= layout; Type =:= frame; Type =:= chart -> byte_size(term_to_binary(Item));
        _ -> byte_size(maps:get(text, Item, maps:get(data, Item, <<>>)))
    end,
    case Size + Bytes =< 2800000 of
        true -> cap_kino_frame(Rest, [Item | Acc], Size + Bytes);
        false -> Acc
    end.

frame_item({chart, Id, Pid}) ->
    case connect_chart(Pid, Id) of
        {ok, Spec, Datasets} ->
            put({kino_chart, Id}, true),
            #{type => chart, id => Id, spec => Spec, datasets => Datasets};
        error -> #{type => text, text => <<"Unable to load the Kino chart.">>}
    end;
frame_item(#{type := frame, id := Id, items := Items} = Frame) ->
    Content = case get({kino_frame_content, Id}) of
        undefined -> frame_apply(Id, replace, Items);
        Current -> Current
    end,
    Frame#{items => Content, revision => get({kino_frame_revision, Id})};
frame_item(#{type := layout, items := Items} = Layout) ->
    Layout#{items => [frame_item(Item) || Item <- Items]};
frame_item({nested, #{id := Id, type := select, value := Index, ref := Ref, destination := Dest, private := Options} = Spec}) ->
    {Default, _} = lists:nth(Index + 1, Options),
    {Actual, SelectedIndex} = case get({kino_input, Id}) of
        #{type := select, value := Previous} ->
            case select_options(Options, Previous, 0, [], undefined) of
                {ok, _, I} -> {Previous, I};
                error -> {Default, Index}
            end;
        _ -> {Default, Index}
    end,
    put({kino_input, Id}, #{value => Actual, type => select, ref => Ref, destination => Dest, options => Options}),
    #{type => interactive, widget => (maps:without([ref, destination, private], Spec))#{value => SelectedIndex}};
frame_item({nested, #{id := Id, type := date, ref := Ref, destination := Dest, private := Default} = Spec}) ->
    Actual = case get({kino_input, Id}) of #{type := date, value := Previous} -> Previous; _ -> Default end,
    {ok, DateValue} = date_iso(Actual),
    put({kino_input, Id}, #{value => Actual, type => date, ref => Ref, destination => Dest,
                            min => maps:get(min, Spec), max => maps:get(max, Spec)}),
    #{type => interactive, widget => (maps:without([ref, destination, private], Spec))#{value => DateValue}};
frame_item({nested, #{id := Id, type := Type, value := Default, ref := Ref, destination := Dest} = Spec}) ->
    Existing = get({kino_input, Id}),
    Actual = case Existing of #{type := Type, value := Previous} -> Previous; _ -> Default end,
    put({kino_input, Id}, #{value => Actual, type => Type, ref => Ref, destination => Dest,
                            min => maps:get(min, Spec, nil), max => maps:get(max, Spec, nil)}),
    #{type => interactive, widget => (maps:without([ref, destination], Spec))#{value => Actual}};
frame_item(Item) -> Item.

release_unowned(Id) ->
    HasFrame = lists:any(fun({{kino_frame, _}, Ids}) -> lists:member(Id, Ids); (_) -> false end, get()),
    case HasFrame orelse get({kino_direct, Id}) =/= undefined of
        true -> ok;
        false -> release_kino_value(Id)
    end.

loop(OwnerRef, Language, Worker, WorkerRef, Pending) ->
    receive
        {eval, From, Ref, Code, Timeout} when Pending =:= none ->
            Timer = erlang:send_after(Timeout, self(), {timeout, Ref}),
            Worker ! {eval, Ref, Code},
            loop(OwnerRef, Language, Worker, WorkerRef, {From, Ref, Timer, <<>>});
        {eval, From, Ref, _, _} ->
            From ! {Ref, result(error, <<"Console is busy.">>, <<>>)},
            loop(OwnerRef, Language, Worker, WorkerRef, Pending);
        {evaluated, Ref, Status, Value, Widget} when Pending =/= none, element(2, Pending) =:= Ref ->
            {From, Ref, Timer, Output} = Pending,
            erlang:cancel_timer(Timer),
            Response = case Widget of
                {#{type := frame, id := FrameId, items := Items} = Public, _, _} ->
                    retain_root({kino_frame_root, FrameId}),
                    Rendered = case get({kino_frame_content, FrameId}) of
                        undefined -> frame_apply(FrameId, replace, Items);
                        Current -> Current
                    end,
                    Revision = get({kino_frame_revision, FrameId}),
                    (result(Status, <<>>, Output))#{widget => Public#{items => Rendered, revision => Revision}};
                {#{type := layout, id := LayoutId, items := Items} = Public, _, _} ->
                    retain_root({kino_frame_root, LayoutId}),
                    Rendered = frame_apply(LayoutId, replace, Items),
                    (result(Status, <<>>, Output))#{widget => Public#{items => Rendered}};
                {#{type := live_chart, id := ChartId}, ChartPid, _} ->
                    case connect_chart(ChartPid, ChartId) of
                        {ok, Spec, Datasets} ->
                            retain_root({kino_chart_direct, ChartId}),
                            put({kino_chart, ChartId}, true),
                            (result(Status, <<>>, Output))#{widget => #{type => chart, id => ChartId, spec => Spec, datasets => Datasets}};
                        error -> result(error, <<"Unable to connect to the Kino chart.">>, Output)
                    end;
                {#{type := Type} = Public, _, _} when Type =:= image; Type =:= markdown; Type =:= plain_text; Type =:= chart ->
                    (result(Status, <<>>, Output))#{widget => Public};
                {#{id := Id, type := select, value := Index} = Public, WidgetRef, Dest, Options} ->
                    retain_root({kino_direct, Id}),
                    #{widget := Current} = frame_item({nested, Public#{ref => WidgetRef, destination => Dest, private => Options, value => Index}}),
                    (result(Status, <<>>, Output))#{widget => Current};
                {#{id := Id, type := date} = Public, WidgetRef, Dest, Default} ->
                    retain_root({kino_direct, Id}),
                    #{widget := Current} = frame_item({nested, Public#{ref => WidgetRef, destination => Dest, private => Default}}),
                    (result(Status, <<>>, Output))#{widget => Current};
                {#{id := Id, value := Default, type := Type} = Public, WidgetRef, Dest} ->
                    retain_root({kino_direct, Id}),
                    #{widget := Current} = frame_item({nested, Public#{ref => WidgetRef, destination => Dest, value => Default}}),
                    Display = case Type of password -> <<>>; _ -> Value end,
                    (result(Status, Display, Output))#{widget => Current};
                none -> result(Status, Value, Output)
            end,
            From ! {Ref, Response},
            loop(OwnerRef, Language, Worker, WorkerRef, none);
        {set_input, From, Ref, Id, Value} ->
            Reply = case get({kino_input, Id}) of
                undefined -> {error, not_found};
                #{type := select, options := Options} = Input ->
                    try binary_to_integer(Value) of
                        N when N >= 0, N < length(Options) ->
                            {Selected, _} = lists:nth(N + 1, Options),
                            put({kino_input, Id}, Input#{value => Selected}),
                            sync_kino_frames(Id, N), notify_kino(Input, Selected), ok;
                        _ -> {error, invalid_value}
                    catch error:badarg -> {error, invalid_value} end;
                #{type := date} = Input ->
                    case input_value(date, Value) of
                        {ok, Converted} ->
                            Min = maps:get(min, Input), Max = maps:get(max, Input),
                            case Value =:= <<>> orelse ((Min =:= nil orelse Value >= Min) andalso (Max =:= nil orelse Value =< Max)) of
                                true -> put({kino_input, Id}, Input#{value => Converted}), sync_kino_frames(Id, case Value of <<>> -> nil; _ -> Value end), notify_kino(Input, Converted), ok;
                                false -> {error, invalid_value}
                            end;
                        error -> {error, invalid_value}
                    end;
                #{type := Type} = Input ->
                    case input_value(Type, Value) of
                        {ok, Converted} when Converted =:= nil orelse not is_number(Converted) ->
                            put({kino_input, Id}, Input#{value => Converted}),
                            case Type of button -> ok; _ -> sync_kino_frames(Id, Converted) end,
                            notify_kino(Input, Converted), ok;
                        {ok, Converted} ->
                            Min = maps:get(min, Input, nil), Max = maps:get(max, Input, nil),
                            case (Min =:= nil orelse (is_number(Min) andalso Converted >= Min)) andalso
                                 (Max =:= nil orelse (is_number(Max) andalso Converted =< Max)) of
                                true -> put({kino_input, Id}, Input#{value => Converted}), sync_kino_frames(Id, Converted), notify_kino(Input, Converted), ok;
                                false -> {error, invalid_value}
                            end;
                        error -> {error, invalid_value}
                    end
            end,
            From ! {Ref, Reply},
            loop(OwnerRef, Language, Worker, WorkerRef, Pending);
        {release_input, From, Ref, Id} ->
            release_root({kino_chart_direct, Id}), release_chart_if_unowned(Id), release_root({kino_direct, Id}), release_unowned(Id), From ! {Ref, ok},
            loop(OwnerRef, Language, Worker, WorkerRef, Pending);
        {release_frame, From, Ref, Id} ->
            release_kino_frame(Id), From ! {Ref, ok},
            loop(OwnerRef, Language, Worker, WorkerRef, Pending);
        {timeout, Ref} when Pending =/= none, element(2, Pending) =:= Ref ->
            {From, Ref, _, Output} = Pending,
            exit(Worker, kill), demonitor(WorkerRef, [flush]),
            From ! {Ref, result(error, <<"Evaluation timed out; bindings were reset. Side effects are not undone.">>, Output)},
            {Next, NextRef} = worker_start(Language),
            loop(OwnerRef, Language, Next, NextRef, none);
        {'DOWN', OwnerRef, process, _, _} -> clear_kino(), exit(Worker, kill);
        {'DOWN', WorkerRef, process, _, Reason} ->
            case Pending of
                {From, Ref, Timer, Output} ->
                    erlang:cancel_timer(Timer),
                    From ! {Ref, result(error, format({evaluator_exited, Reason}), Output)};
                none -> ok
            end,
            {Next, NextRef} = worker_start(Language),
            loop(OwnerRef, Language, Next, NextRef, none);
        {runtime_broadcast, <<"js_live">>, ChartId, {event, Event, Payload, #{ref := ChartId}}}
          when Event =:= <<"push">>; Event =:= <<"set_param">> ->
            case get({kino_chart, ChartId}) of
                true when is_map(Payload) ->
                    case byte_size(term_to_binary(Payload)) =< 1048576 of
                        true -> get(beamdash_owner) ! {beamdash_kino_chart, self(), ChartId, Event, Payload};
                        false -> ok
                    end;
                _ -> ok
            end,
            loop(OwnerRef, Language, Worker, WorkerRef, Pending);
        {io_request, From, ReplyAs, {livebook_put_output, #{type := frame_update, ref := FrameRef, update := {Action, Outputs}}}}
          when is_binary(FrameRef), byte_size(FrameRef) =< 256, (Action =:= replace orelse Action =:= append) ->
            case frame_outputs(Outputs) of
                {ok, Items} ->
                    Rendered = frame_apply(FrameRef, Action, Items),
                    sync_parent_frames(FrameRef, Rendered, get({kino_frame_revision, FrameRef})),
                    get(beamdash_owner) ! {beamdash_kino_frame, self(), FrameRef, get({kino_frame_revision, FrameRef}), Rendered},
                    From ! {io_reply, ReplyAs, ok};
                error -> From ! {io_reply, ReplyAs, {error, {request, unsupported}}}
            end,
            loop(OwnerRef, Language, Worker, WorkerRef, Pending);
        {io_request, From, ReplyAs, Request} ->
            {Reply, Text} = io_request(Request),
            From ! {io_reply, ReplyAs, Reply},
            NextPending = case Pending of
                {Caller, Ref, Timer, Output} -> {Caller, Ref, Timer, limit(<<Output/binary, Text/binary>>, 64000)};
                none ->
                    case Text of
                        <<>> -> ok;
                        _ -> get(beamdash_owner) ! {beamdash_console_output, self(), Text}
                    end,
                    none
            end,
            loop(OwnerRef, Language, Worker, WorkerRef, NextPending);
        stop -> clear_kino(), exit(Worker, kill);
        _ -> loop(OwnerRef, Language, Worker, WorkerRef, Pending)
    end.

%% A connect reply is ordered after earlier broadcasts from the same Kino server.
%% Discard those broadcasts: the connect snapshot already includes their data.
connect_chart(Pid, Id) ->
    Pid ! {connect, self(), #{origin => <<"beamdash">>, ref => Id}},
    connect_chart_reply(Id, erlang:monotonic_time(millisecond) + 1000).
connect_chart_reply(Id, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {io_request, From, ReplyAs, livebook_get_broadcast_target} ->
            From ! {io_reply, ReplyAs, {ok, self()}},
            connect_chart_reply(Id, Deadline);
        {runtime_broadcast, <<"js_live">>, Id, _} -> connect_chart_reply(Id, Deadline);
        {connect_reply, #{spec := Spec, datasets := Datasets}, #{ref := Id}}
          when is_map(Spec), is_list(Datasets) ->
            case byte_size(term_to_binary({Spec, Datasets})) =< 1048576 of
                true -> {ok, Spec, Datasets}; false -> error
            end
    after Remaining -> error
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
io_request(livebook_get_broadcast_target) -> {{ok, self()}, <<>>};
io_request(getopts) -> {{ok, [{encoding, unicode}]}, <<>>};
io_request({setopts, _}) -> {ok, <<>>};
io_request({livebook_put_output, #{type := Type, text := Text}})
  when (Type =:= plain_text orelse Type =:= terminal_text), is_binary(Text) ->
    {ok, limit(Text, 64000)};
io_request({livebook_put_output, _}) -> {{error, {request, unsupported}}, <<>>};
io_request(livebook_generate_token) -> {make_ref(), <<>>};
io_request({livebook_reference_object, _, _}) -> {{error, {request, unsupported}}, <<>>};
io_request({livebook_monitor_object, _, _, _, _}) -> {{error, {request, unsupported}}, <<>>};
io_request({livebook_monitor_object, _, _, _}) -> {{error, {request, unsupported}}, <<>>};
io_request({livebook_get_input_value, Id, _}) -> kino_input(Id);
io_request({livebook_get_input_value, Id}) -> kino_input(Id);
io_request(_) -> {{error, enotsup}, <<>>}.
kino_input(Id) ->
    case get({kino_input, Id}) of
        undefined -> {{error, not_found}, <<>>};
        #{value := Value} -> {{ok, Value}, <<>>}
    end.
input_value(Type, Value) when Type =:= text; Type =:= textarea -> {ok, Value};
input_value(password, Value) -> {ok, Value};
input_value(url, <<>>) -> {ok, nil};
input_value(url, Value) ->
    try uri_string:parse(Value) of
        #{scheme := Scheme} when byte_size(Scheme) > 0 -> {ok, Value};
        _ -> error
    catch _:_ -> error end;
input_value(date, <<>>) -> {ok, nil};
input_value(date, Value) ->
    try 'Elixir.Date':from_iso8601(Value) of
        {ok, Date} -> {ok, Date};
        _ -> error
    catch _:_ -> error end;
input_value(color, Value) ->
    case re:run(Value, <<"^#[0-9a-fA-F]{6}$">>, [{capture, none}]) of
        match -> {ok, Value};
        nomatch -> error
    end;
input_value(checkbox, <<"true">>) -> {ok, true};
input_value(checkbox, <<"false">>) -> {ok, false};
input_value(number, <<>>) -> {ok, nil};
input_value(Type, Value) when Type =:= number; Type =:= range ->
    try {ok, binary_to_integer(Value)} catch error:badarg ->
        try {ok, binary_to_float(Value)} catch error:badarg -> error end
    end;
input_value(button, <<"click">>) -> {ok, click};
input_value(_, _) -> error.
notify_kino(#{ref := Ref, destination := {'Elixir.Kino.SubscriptionManager', Node}, type := Type}, Value)
  when is_binary(Ref), Node =:= node() ->
    Event = case Type of
        button -> #{type => click, origin => <<"beamdash">>};
        _ -> #{type => change, origin => <<"beamdash">>, value => Value}
    end,
    {'Elixir.Kino.SubscriptionManager', Node} ! {event, Ref, Event}, ok;
notify_kino(_, _) -> ok.
clear_kino() ->
    [release_kino_value(Id) || {{kino_input, Id}, _} <- get()],
    ok.
retain_root(Key) ->
    Count = case get(Key) of undefined -> 0; N -> N end,
    put(Key, Count + 1), ok.
release_root(Key) ->
    case get(Key) of N when is_integer(N), N > 1 -> put(Key, N - 1); _ -> erase(Key) end, ok.
release_kino_frame(Id) ->
    release_root({kino_frame_root, Id}), release_frame_if_unowned(Id).
release_frame_if_unowned(Id) ->
    Owned = get({kino_frame_root, Id}) =/= undefined orelse
        lists:any(fun({{kino_frame_children, Parent}, Children}) ->
                          Parent =/= Id andalso lists:member(Id, Children);
                     (_) -> false end, get()),
    case Owned of
        true -> ok;
        false ->
            Children = case erase({kino_frame_children, Id}) of undefined -> []; C -> C end,
            Charts = case erase({kino_frame_charts, Id}) of undefined -> []; A -> A end,
            case erase({kino_frame, Id}) of
                Ids when is_list(Ids) ->
                    erase({kino_frame_content, Id}), erase({kino_frame_revision, Id}),
                    [release_unowned(Child) || Child <- Ids],
                    [release_frame_if_unowned(Child) || Child <- Children, Child =/= Id],
                    [release_chart_if_unowned(Chart) || Chart <- Charts], ok;
                _ -> ok
            end
    end.

release_chart_if_unowned(Id) ->
    Owned = get({kino_chart_direct, Id}) =/= undefined orelse
        lists:any(fun({{kino_frame_charts, _}, Ids}) -> lists:member(Id, Ids); (_) -> false end, get()),
    case Owned of true -> ok; false -> erase({kino_chart, Id}), ok end.

sync_parent_frames(Id, Items, Revision) ->
    [put({kino_frame_content, Parent}, [replace_frame_item(Item, Id, Items, Revision) || Item <- Content])
     || {{kino_frame_content, Parent}, Content} <- get(), Parent =/= Id], ok.
replace_frame_item(#{type := frame, id := Id} = Frame, Id, Items, Revision) ->
    Frame#{items => Items, revision => Revision};
replace_frame_item(#{type := Type, items := Children} = Item, Id, Items, Revision)
  when Type =:= frame; Type =:= layout ->
    Item#{items => [replace_frame_item(C, Id, Items, Revision) || C <- Children]};
replace_frame_item(Item, _, _, _) -> Item.

release_kino_value(Id) ->
    case erase({kino_input, Id}) of
        #{ref := Ref, destination := {'Elixir.Kino.SubscriptionManager', Node}} when is_binary(Ref), Node =:= node() ->
            {'Elixir.Kino.SubscriptionManager', Node} ! {clear_topic, Ref}, ok;
        _ -> ok
    end.
chars(Chars) ->
    try {ok, limit(unicode:characters_to_binary(Chars), 64000)} catch _:_ -> {{error, badarg}, <<>>} end.
limit(Bin, Size) when byte_size(Bin) =< Size -> Bin;
limit(Bin, Size) ->
    Prefix = binary:part(Bin, 0, Size),
    case unicode:characters_to_binary(Prefix) of
        Good when is_binary(Good) -> Good;
        {_, Good, _} -> Good
    end.
