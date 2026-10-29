%%% Serialize beamdash deployments on the target node. Other code loaders must
%%% still be paused, because the code server has no conditional load operation.
-module(beamdash_module_deploy).
-export([load/4]).

load(Mod, Beam, Expected, Digest) when is_atom(Mod), is_binary(Beam),
                                       is_binary(Expected), is_binary(Digest) ->
    Lock = {{beamdash_module_deploy, Mod}, self()},
    case global:trans(Lock, fun() -> checked_load(Mod, Beam, Expected, Digest) end, [node()], 0) of
        aborted -> {error, <<"another beamdash deployment is in progress">>};
        Result -> Result
    end.

checked_load(Mod, Beam, Expected, Digest) ->
    try Mod:module_info(md5) of
        Expected ->
            case code:load_binary(Mod, "beamdash", Beam) of
                {module, Mod} -> {ok, Digest};
                Error -> {error, Error}
            end;
        _ -> {error, module_changed}
    catch
        error:Reason -> {error, Reason}
    end.
