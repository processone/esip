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
-export([start_link/0, start_link/3, start/0, start/3,
         connect/1, connect/2, send/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").

-record(state, {type, addr, peer, sock, buf = <<>>, max_size,
                location, msg, wait_size}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link(?MODULE, [], []).

start_link(Sock, Peer, MyAddr) ->
    gen_server:start_link(?MODULE, [Sock, Peer, MyAddr], []).

start() ->
    esip_tmp_sup:start_child(esip_tcp_sup, ?MODULE, gen_server, []).

start(Sock, Peer, MyAddr) ->
    esip_tmp_sup:start_child(esip_tcp_sup, ?MODULE,
                             gen_server, [Sock, Peer, MyAddr]).

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
    {ok, #state{max_size = MaxSize}};
init([Sock, Peer, MyAddr]) ->
    inet:setopts(Sock, [{active, once}]),
    MaxSize = esip:get_config_value(max_msg_size),
    {ok, #state{max_size = MaxSize,
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

handle_info({tcp, Sock, Data}, State) ->
    inet:setopts(Sock, [{active, once}]),
    esip:callback(data_in, [Data, make_sip_socket(State)]),
    process_data(State, Data);
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

process_data(#state{buf = Buf, max_size = MaxSize,
                    msg = undefined} = State, Data) ->
    NewBuf = process_crlf(<<Buf/binary, Data/binary>>, State),
    case catch esip_codec:decode(NewBuf, stream) of
        {ok, Msg, Tail} ->
            case esip:get_hdr('content-length', Msg#sip.hdrs) of
                N when is_integer(N), N >= 0, N =< MaxSize ->
                    process_data(State#state{buf = <<>>,
                                             msg = Msg,
                                             wait_size = N}, Tail);
                _ ->
                    {stop, normal, State}
            end;
        more when size(NewBuf) < MaxSize ->
            {noreply, State#state{buf = NewBuf}};
        _ ->
            {stop, normal, State}
    end;
process_data(#state{buf = Buf, max_size = MaxSize,
                    msg = Msg, wait_size = WaitSize} = State, Data) ->
    NewBuf = <<Buf/binary, Data/binary>>,
    case NewBuf of
        <<Body:WaitSize/binary, Tail/binary>> ->
            NewState = State#state{buf = Tail, msg = undefined},
            transport_recv(NewState, Msg#sip{body = Body}),
            process_data(NewState, <<>>);
        _ when size(NewBuf) < MaxSize ->
            {noreply, State#state{buf = NewBuf}};
        _ ->
            {stop, normal, State}
    end.

transport_recv(State, Msg) ->
    SIPSock = make_sip_socket(State),
    case catch esip_transport:recv(SIPSock, Msg) of
        {'EXIT', Reason} ->
            ?ERROR_MSG("transport layer failed:~n"
                       "** Packet: ~p~n** Reason: ~p",
                       [Msg, Reason]);
        _ ->
            ok
    end.

process_crlf(<<"\r\n\r\n", Data/binary>>, State) ->
    DataOut = <<"\r\n">>,
    esip:callback(data_out, [DataOut, make_sip_socket(State)]),
    gen_tcp:send(State#state.sock, DataOut),
    process_crlf(Data, State);
process_crlf(Data, _State) ->
    Data.
