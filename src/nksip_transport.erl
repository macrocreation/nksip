%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkSIP Transport control module
-module(nksip_transport).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_all/0, get_all/1, get_listening/3, get_connected/2, get_connected/5]).
-export([is_local/2, is_local_ip/1]).
-export([start_transport/5, default_port/1]).
-export([get_listenhost/3, make_route/6]).
-export([send/4]).
-export([get_all_connected/0, get_all_connected/1, stop_all_connected/0]).

-export_type([transport/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-compile({no_auto_import,[get/1]}).


%% ===================================================================
%% Types
%% ===================================================================

-type transport() :: #transport{}.

-type connection() :: 
    {nksip:protocol(), inet:ip_address(), inet:port_number(), binary()}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets all registered transports in all Services.
-spec get_all() -> 
    [{nkservice:id(), transport(), pid()}].

get_all() ->
    All = [{SrvId, Transp, Pid} 
            || {{SrvId, Transp}, Pid} <- nklib_proc:values(nksip_transports)],
    lists:sort(All).


%% @doc Gets all registered transports for a Service.
-spec get_all(nkservice:id()) -> 
    [{transport(), pid()}].

get_all(SrvId) ->
    [{Transp, Pid} || {A, Transp, Pid} <- get_all(), SrvId==A].


%% @private Finds a listening transport of Proto.
-spec get_listening(nkservice:id(), nksip:protocol(), ipv4|ipv6) -> 
    [{transport(), pid()}].

get_listening(SrvId, Proto, Class) ->
    Fun = fun({#transport{proto=TProto, listen_ip=TListen}, _}) -> 
        case TProto==Proto of
            true ->
                case Class of
                    ipv4 when size(TListen)==4 -> true;
                    ipv6 when size(TListen)==8 -> true;
                    _ -> false
                end;
            false ->
                false
        end
    end,
    lists:filter(Fun, nklib_proc:values({nksip_listen, SrvId})).


%% @private Finds a listening transport of Proto
-spec get_connected(nkservice:id(), nksip:transport()|undefined) ->
    [{nksip_transport:transport(), pid()}].

get_connected(SrvId, Transp) ->
    case Transp of
        #transport{proto=Proto, remote_ip=Ip, remote_port=Port, resource=Res} ->
            get_connected(SrvId, Proto, Ip, Port, Res);
        _ ->
            []
    end.


%% @private Finds a listening transport of Proto
-spec get_connected(nkservice:id(), nksip:protocol(), 
                    inet:ip_address(), inet:port_number(), binary()) ->
    [{nksip_transport:transport(), pid()}].

get_connected(SrvId, Proto, Ip, Port, Res) ->
    nklib_proc:values({nksip_connection, {SrvId, Proto, Ip, Port, Res}}).


%% @doc Checks if an `nksip:uri()' or `nksip:via()' refers to a local started transport.
-spec is_local(nkservice:id(), Input::nksip:uri()|nksip:via()) -> 
    boolean().

is_local(SrvId, #uri{}=Uri) ->
    Listen = [
        {Proto, Ip, Port, Res} ||
        {#transport{proto=Proto, listen_ip=Ip, listen_port=Port, resource=Res}, _Pid} 
        <- nklib_proc:values({nksip_listen, SrvId})
    ],
    is_local(Listen, nksip_dns:resolve(Uri), nksip_config_cache:local_ips());

is_local(SrvId, #via{}=Via) ->
    {Proto, Host, Port} = nksip_parse:transport(Via),
    Transp = {<<"transport">>, nklib_util:to_binary(Proto)},
    Uri = #uri{scheme=sip, domain=Host, port=Port, opts=[Transp]},
    is_local(SrvId, Uri).


%% @private
is_local(Listen, [{Proto, Ip, Port, Res}|Rest], LocalIps) -> 
    case lists:member(Ip, LocalIps) of
        true ->
            case lists:member({Proto, Ip, Port, Res}, Listen) of
                true ->
                    true;
                false ->
                    case 
                        is_tuple(Ip) andalso size(Ip)==4 andalso
                        lists:member({Proto, {0,0,0,0}, Port, Res}, Listen) 
                    of
                        true -> 
                            true;
                        false -> 
                            case 
                                is_tuple(Ip) andalso size(Ip)==8 andalso
                                lists:member({Proto, {0,0,0,0,0,0,0,0}, Port, Res}, Listen) 
                            of
                                true -> true;
                                false -> is_local(Listen, Rest, LocalIps)
                            end
                    end
            end;
        false ->
            is_local(Listen, Rest, LocalIps)
    end;

is_local(_, [], _) ->
    false.


%% @doc Checks if an IP is local to this node.
-spec is_local_ip(inet:ip_address()) -> 
    boolean().

is_local_ip({0,0,0,0}) ->
    true;
is_local_ip({0,0,0,0,0,0,0,0}) ->
    true;
is_local_ip(Ip) ->
    lists:member(Ip, nksip_config_cache:local_ips()).


%% @doc Start a new listening transport.
%% Opts should have the transport options ++ Service configuration
-spec start_transport(nkservice:id(), nksip:protocol(), inet:ip_address(), 
                      inet:port_number(), nksip:optslist()) ->
    {ok, pid()} | {error, term()}.

start_transport(SrvId, Proto, Ip, Port, Opts) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    Listening = [
        {{LIp, LPort}, Pid} || 
            {#transport{listen_ip=LIp, listen_port=LPort}, Pid} 
            <- get_listening(SrvId, Proto, Class)
    ],
    case nklib_util:get_value({Ip, Port}, Listening) of
        undefined -> 
            Transp = #transport{
                proto = Proto,
                local_ip = Ip, 
                local_port = Port,
                listen_ip = Ip,
                listen_port = Port,
                remote_ip = {0,0,0,0},
                remote_port = 0
            },
            Spec = case Proto of
                udp -> nksip_transport_udp:get_listener(SrvId, Transp, Opts);
                tcp -> nksip_transport_tcp:get_listener(SrvId, Transp, Opts);
                tls -> nksip_transport_tcp:get_listener(SrvId, Transp, Opts);
                sctp -> nksip_transport_sctp:get_listener(SrvId, Transp, Opts);
                ws -> nksip_transport_ws:get_listener(SrvId, Transp, Opts);
                wss -> nksip_transport_ws:get_listener(SrvId, Transp, Opts)
            end,
            nkservice_transport_sup:add_transport(SrvId, Spec);
        Pid when is_pid(Pid) -> 
            {ok, Pid}
    end.



%% @private 
-spec get_listenhost(nkservice:id(), inet:ip_address(), nksip:optslist()) ->
    binary().

get_listenhost(SrvId, Ip, Opts) ->
    case size(Ip) of
        4 ->
            Host = case nklib_util:get_value(sip_local_host, Opts) of
                undefined -> SrvId:cache_sip_local_host();
                Host0 -> Host0
            end,
            case Host of
                auto when Ip == {0,0,0,0} -> 
                    nklib_util:to_host(nksip_config_cache:main_ip()); 
                auto ->
                    nklib_util:to_host(Ip);
                _ -> 
                    Host
            end;
        8 ->
            Host = case nklib_util:get_value(sip_local_host6, Opts) of
                undefined -> SrvId:cache_sip_local_host6();
                Host0 -> Host0
            end,
            case Host of
                auto when Ip == {0,0,0,0,0,0,0,0} -> 
                    nklib_util:to_host(nksip_config_cache:main_ip6(), true);
                auto -> 
                    nklib_util:to_host(Ip, true);
                _ -> 
                    Host
            end
    end.

    
%% @private Makes a route record
-spec make_route(nksip:scheme(), nksip:protocol(), binary(), inet:port_number(),
                 binary(), nksip:optslist()) ->
    #uri{}.

make_route(Scheme, Proto, ListenHost, Port, User, Opts) ->
    UriOpts = case Proto of
        tls when Scheme==sips -> Opts;
        udp when Scheme==sip -> Opts;
        _ -> [{<<"transport">>, nklib_util:to_binary(Proto)}|Opts] 
    end,
    #uri{
        scheme = Scheme,
        user = User,
        domain = ListenHost,
        port = Port,
        opts = UriOpts
    }.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec send(nkservice:id(), [TSpec], function(), nksip:optslist()) ->
    {ok, nksip:request()|nksip:response()} | error
    when TSpec :: #uri{} | connection() | {current, connection()} | 
                  {flow, {pid(), nksip:transport()}}.

send(SrvId, [#uri{}=Uri|Rest], MakeMsg, Opts) ->
    Resolv = nksip_dns:resolve(Uri),
    ?call_debug("Transport send to ~p (~p)", [Resolv, Rest]),
    send(SrvId, Resolv++Rest, MakeMsg, [{transport_uri, Uri}|Opts]);

send(SrvId, [{current, {udp, Ip, Port, Res}}|Rest], MakeMsg, Opts) ->
    send(SrvId, [{udp, Ip, Port, Res}|Rest], MakeMsg, Opts);

send(SrvId, [{current, {Proto, Ip, Port, Res}=D}|Rest], MakeMsg, Opts) ->
    ?call_debug("Transport send to current ~p (~p)", [D, Rest]),
    case get_connected(SrvId, Proto, Ip, Port, Res) of
        [{Transp, Pid}|_] -> 
            SipMsg = MakeMsg(Transp),
            case nksip_connection:send(Pid, SipMsg) of
                ok -> 
                    {ok, SipMsg};
                {error, _Error} -> 
                    send(SrvId, Rest, MakeMsg, Opts)
            end;
        [] ->
            send(SrvId, Rest, MakeMsg, Opts)
    end;

send(SrvId, [{flow, {Pid, Transp}=D}|Rest], MakeMsg, Opts) ->
    ?call_debug("Transport send to flow ~p (~p)", [D, Rest]),
    SipMsg = MakeMsg(Transp),
    case nksip_connection:send(Pid, SipMsg) of
        ok -> 
            {ok, SipMsg};
        {error, _} -> 
            send(SrvId, Rest, MakeMsg, Opts)
    end;

send(SrvId, [{Proto, Ip, 0, Res}|Rest], MakeMsg, Opts) ->
    send(SrvId, [{Proto, Ip, default_port(Proto), Res}|Rest], MakeMsg, Opts);

send(SrvId, [{Proto, Ip, Port, Res}=D|Rest], MakeMsg, Opts) ->
    case get_connected(SrvId, Proto, Ip, Port, Res) of
        [{Transp, Pid}|_] -> 
            ?call_debug("Transport send to connected ~p (~p)", [D, Rest]),
            SipMsg = MakeMsg(Transp),
            case nksip_connection:send(Pid, SipMsg) of
                ok -> 
                    {ok, SipMsg};
                {error, udp_too_large} ->
                    send(SrvId, [{tcp, Ip, Port, Res}|Rest], MakeMsg, Opts);
                {error, _} -> 
                    send(SrvId, Rest, MakeMsg, Opts)
            end;
        [] ->
            ?call_debug("Transport send to new ~p (~p)", [D, Rest]),
            case connect(SrvId, Proto, Ip, Port, Res, Opts) of
                {ok, Pid, Transp} ->
                    SipMsg = MakeMsg(Transp),
                    case nksip_connection:send(Pid, SipMsg) of
                        ok -> 
                            {ok, SipMsg};
                        {error, udp_too_large} ->
                            send(SrvId, [{tcp, Ip, Port, Res}|Rest], MakeMsg, Opts);
                        {error, Error} -> 
                            ?call_warning("Error sending to new transport: ~p", [Error]),
                            send(SrvId, Rest, MakeMsg, Opts)
                    end;
                {error, Error} ->
                    ?call_notice("error connecting to ~p:~p (~p): ~p",
                                [Ip, Port, Proto, Error]),
                    send(SrvId, Rest, MakeMsg, Opts)
            end
    end;

send(SrvId, [Other|Rest], MakeMsg, Opts) ->
    ?call_warning("invalid send specification: ~p", [Other]),
    send(SrvId, Rest, MakeMsg, Opts);

send(_, [], _MakeMsg, _Opts) ->
    error.
        


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new outbound connection.
-spec connect(nkservice:id(), nksip:protocol(),
                       inet:ip_address(), inet:port_number(), binary(), 
                       nksip:optslist()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.

%% Do not open simultanous connections to the same destination
connect(SrvId, Proto, Ip, Port, Res, Opts) ->
    try_connect(SrvId, Proto, Ip, Port, Res, Opts, 300).
    

%% @private
try_connect(_, _, _, _, _, _, 0) ->
    {error, connection_busy};

try_connect(SrvId, udp, Ip, Port, Res, Opts, _Try) ->
    do_connect(SrvId, udp, Ip, Port, Res, Opts);

try_connect(SrvId, Proto, Ip, Port, Res, Opts, Try) ->
    ConnId = {SrvId, Proto, Ip, Port, Res},
    case nkservice_server:put_new(SrvId, {nksip_connect_block, ConnId}, true) of
        true ->
            try 
                do_connect(SrvId, Proto, Ip, Port, Res, Opts)
            catch
                error:Value -> 
                    ?call_warning("Exception ~p launching connection: ~p", 
                                  [Value, erlang:get_stacktrace()]),
                    {error, Value}
            after
                nkservice_server:del(SrvId, {nksip_connect_block, ConnId})
            end;
        false ->
            timer:sleep(100),
            try_connect(SrvId, Proto, Ip, Port, Res, Opts, Try-1);
        {error, _} ->
            {error, locking_error}
    end.
                

%% @private Starts a new connection to a remote server
-spec do_connect(nkservice:id(), nksip:protocol(), inet:ip_address(), inet:port_number(), 
              binary(), nksip:optslist()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.
         
do_connect(SrvId, Proto, Ip, Port, Res, Opts) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(SrvId, Proto, Class) of
        [{Transp, Pid}|_] -> 
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, resource=Res},
            case Proto of
                udp -> nksip_transport_udp:connect(Pid, Transp1);
                tcp -> nksip_transport_tcp:connect(SrvId, Transp1);
                tls -> nksip_transport_tcp:connect(SrvId, Transp1);
                sctp -> nksip_transport_sctp:connect(Pid, Transp1);
                ws -> nksip_transport_ws:connect(SrvId, Transp1, Opts);
                wss -> nksip_transport_ws:connect(SrvId, Transp1, Opts)
            end;
        [] ->
            {error, no_listening_transport}
    end.


%% @private
default_port(udp) -> 5060;
default_port(tcp) -> 5060;
default_port(tls) -> 5061;
default_port(sctp) -> 5060;
default_port(ws) -> 80;
default_port(wss) -> 443;
default_port(_) -> 0.



%% ===================================================================
%% Only testing
%% ===================================================================


%% @private
get_all_connected() ->
    nklib_proc:fold_names(
        fun(Name, Values, Acc) ->
            case Name of
                {nksip_connection, {SrvId, _Proto, _Ip, _Port, _Res}} -> 
                    [{SrvId, Transp, Pid} || {val, Transp, Pid} <- Values] ++ Acc;
                _ ->
                    Acc
            end
        end,
        []).


%% @private
get_all_connected(SrvId) ->
    [{Transp, Pid} || {LSrvId, Transp, Pid} <- get_all_connected(), SrvId==LSrvId].


%% @private
stop_all_connected() ->
    lists:foreach(
        fun({_, _, Pid}) -> nksip_connection:stop(Pid, normal) end,
        get_all_connected()).




