%%% Custom EPMD discovery module (see ERTS "Alternative Node Discovery"
%%% guide), installed as `kernel, epmd_module` the first time a kubectl
%%% connection is made (see Beamdash.Kubectl).
%%%
%%% Delegates everything to the real erl_epmd, except address_please/3 for
%%% whichever one node Beamdash.Kubectl is currently tunnelling to: that is
%%% redirected to the local kubectl port-forward instead of the node's real,
%%% cluster-internal (and therefore unroutable) address.
%%%
%%% The target is kept in a persistent_term (set by Beamdash.Kubectl before
%%% connecting, erased when the tunnel closes) rather than process
%%% dictionary or application env, since beamdash is a long-running node and
%%% the target changes across connects.
-module(beamdash_epmd).

-export([start_link/0, names/1, register_node/3, port_please/2,
         address_please/3, listen_port_please/2]).

-define(TARGET_KEY, {beamdash_epmd, target}).

start_link() ->
    erl_epmd:start_link().

names(Host) ->
    erl_epmd:names(Host).

register_node(Name, Port, Family) ->
    erl_epmd:register_node(Name, Port, Family).

port_please(Name, Host) ->
    erl_epmd:port_please(Name, Host).

listen_port_please(Name, Host) ->
    erl_epmd:listen_port_please(Name, Host).

address_please(Name, Host, AddressFamily) ->
    case persistent_term:get(?TARGET_KEY, undefined) of
        {Name, Port} ->
            {ok, {127, 0, 0, 1}, Port, 6};
        _ ->
            erl_epmd:address_please(Name, Host, AddressFamily)
    end.
