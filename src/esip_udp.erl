%%%-------------------------------------------------------------------
%%% File    : esip_udp.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Handle UDP sockets
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_udp).

-behaviour(gen_server).

%% API
-export([start_link/3, start/3, stop/0, send/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").

-record(state, {sock, ip, port}).

%%====================================================================
%% API
%%====================================================================
start_link(IP, Port, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [IP, Port, Opts], []).

start(IP, Port, Opts) ->
    ChildSpec =	{?MODULE,
		 {?MODULE, start_link, [IP, Port, Opts]},
		 transient, 2000, worker,
		 [?MODULE]},
    supervisor:start_child(esip_sup, ChildSpec).

stop() ->
    gen_server:call(?MODULE, stop),
    supervisor:delete_child(esip_sup, ?MODULE).

send(Pid, Peer, R) ->
    gen_server:cast(Pid, {Peer, R}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([IP, Port, Opts]) ->
    case gen_udp:open(Port, [{ip, IP}, binary,
			     {active, once} | Opts]) of
	{ok, S} ->
	    {ok, #state{sock = S, ip = IP, port = Port}};
	Err ->
	    Err
    end.

handle_call(stop, _From, State) ->
    {stop, normal, State};
handle_call(_Request, _From, State) ->
    {reply, bad_request, State}.

handle_cast({{IP, Port}, R}, State) ->
    case catch esip_codec:encode(R) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to encode:~n"
		       "** Packet: ~p~n** Reason: ~p",
		       [R, Err]);
	Data ->
	    MyAddr = {State#state.ip, State#state.port},
            case esip:callback(data_out, [udp, MyAddr, {IP, Port}, Data]) of
                drop ->
                    ok;
                NewData when is_binary(Data) ->
                    gen_udp:send(State#state.sock, IP, Port, NewData);
                _ ->
                    gen_udp:send(State#state.sock, IP, Port, Data)
            end
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, S, IP, Port, Data}, #state{sock = S} = State) ->
    MyAddr = {State#state.ip, State#state.port},
    SIPSock = #sip_socket{type = udp, owner = self(),
                          addr = MyAddr, peer = {IP, Port}},
    case esip:callback(data_in, [udp, {IP, Port}, MyAddr, Data]) of
        drop ->
            ok;
        NewData when is_binary(NewData) ->
            transport_recv(SIPSock, NewData);
        _ ->
            transport_recv(SIPSock, Data)
    end,
    inet:setopts(S, [{active, once}]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{sock = S}) ->
    catch gen_udp:close(S),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
transport_recv(SIPSock, Data) ->
    case catch esip_codec:decode(Data) of
        R = #sip{} ->
            case catch esip_transport:recv(SIPSock, R) of
                {'EXIT', Reason} ->
                    ?ERROR_MSG("transport layer failed:~n"
                               "** Packet: ~p~n** Reason: ~p",
                               [R, Reason]);
                _ ->
                    ok
            end;
	Err ->
	    ?ERROR_MSG("failed to decode:~n"
		       "** Data: ~p~n** Reason: ~p",
		       [Data, Err])
    end.
