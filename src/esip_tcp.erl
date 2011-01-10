%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2011, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  6 Jan 2011 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_tcp).

-behaviour(gen_server).

%% API
-export([start_link/0, start/0, start/3, connect/1, connect/2, send/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").

-record(state, {type, addr, peer, sock, codec, location}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link(?MODULE, [], []).

start() ->
    gen_server:start(?MODULE, [], []).

start(Sock, Peer, MyAddr) ->
    gen_server:start(?MODULE, [Sock, Peer, MyAddr], []).

connect(Addrs) ->
    connect(Addrs, []).

connect(Addrs, Opts) ->
    case start() of
        {ok, Pid} ->
            gen_server:call(Pid, {connect, Addrs, Opts}, infinity);
        Err ->
            Err
    end.

send(Sock, Data) ->
    gen_tcp:send(Sock, Data).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    MaxSize = esip:get_config_value(max_msg_size),
    {ok, #state{codec = esip_codec:init(MaxSize, stream)}};
init([Sock, Peer, MyAddr]) ->
    inet:setopts(Sock, [{active, once}]),
    MaxSize = esip:get_config_value(max_msg_size),
    {ok, #state{codec = esip_codec:init(MaxSize, stream),
                sock = Sock,
                peer = Peer,
                addr = MyAddr,
                type = tcp}}.

handle_call({connect, Addrs, Opts}, _From, State) ->
    Type = case lists:keysearch(tls, 1, Opts) of
               {value, {_, true}} ->
                   tls;
               _ ->
                   tcp
           end,
    case do_connect(Addrs) of
        {ok, MyAddr, Peer, Sock} ->
            NewState = State#state{type = Type, sock = Sock,
                                   addr = MyAddr, peer = Peer},
            SIPSock = make_sip_socket(NewState),
            esip_transport:register_socket(Peer, Type, SIPSock),
            {reply, {ok, SIPSock}, NewState};
        Err ->
            {stop, normal, Err, State}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Sock, Data},
            #state{type = Type, addr = Addr, peer = Peer} = State) ->
    inet:setopts(Sock, [{active, once}]),
    esip:callback(data_in, [Type, Peer, Addr, Data]),
    transport_recv(State, Data);
handle_info({tcp_closed, _Sock}, State) ->
    {stop, normal, State};
handle_info({tcp_error, _Sock, _Reason}, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{peer = Peer, type = Type} = State) ->
    SIPSock = make_sip_socket(State),
    esip_transport:unregister_socket(Peer, Type, SIPSock).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_connect([{Addr, Port}|Addrs]) ->
    case gen_tcp:connect(Addr, Port, [binary, {active, once}]) of
        {ok, Sock} ->
            case inet:sockname(Sock) of
                {error, _} = Err ->
                    fail_or_proceed(Err, Addrs);
                {ok, MyAddr} ->
                    {ok, MyAddr, {Addr, Port}, Sock}
            end;
        Err ->
            fail_or_proceed(Err, Addrs)
    end.

fail_or_proceed(Err, []) ->
    Err;
fail_or_proceed(_Err, Addrs) ->
    do_connect(Addrs).

make_sip_socket(#state{type = Type, addr = MyAddr, peer = Peer, sock = Sock}) ->
    #sip_socket{type = Type, addr = MyAddr, sock = Sock, peer = Peer}.

transport_recv(#state{codec = Codec} = State, Data) ->
    case catch esip_codec:decode(Data, Codec) of
        {ok, Msg, NewCodec} ->
            SIPSock = make_sip_socket(State),
            case catch esip_transport:recv(SIPSock, Msg) of
                {'EXIT', Reason} ->
                    ?ERROR_MSG("transport layer failed:~n"
                               "** Packet: ~p~n** Reason: ~p",
                               [Msg, Reason]);
                _ ->
                    ok
            end,
            transport_recv(State#state{codec = NewCodec}, <<>>);
        {more, NewCodec} ->
            {noreply, State#state{codec = NewCodec}};
        Err ->
            ?ERROR_MSG("failed to decode:~n"
                       "** Data: ~p~n"
                       "** Codec: ~p~n"
                       "** Reason: ~p",
                       [Data, Codec, Err]),
            {stop, normal, State}
    end.
