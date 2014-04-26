%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2011, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  6 Jan 2011 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_socket).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

%% API
-export([start_link/0, start_link/1, start_link/2, start/0, start/2,
         connect/1, connect/2, send/2, socket_type/0, udp_recv/5,
	 udp_init/2, start_pool/0, get_pool_size/0, send/3, tcp_init/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").

-define(TCP_SEND_TIMEOUT, 15000).

-record(state, {type, addr, peer, sock, buf = <<>>, max_size,
                location, msg, wait_size}).

%%%===================================================================
%%% API
%%%===================================================================
%% @doc Start TCP client to connect
start_link() ->
    ?GEN_SERVER:start_link(?MODULE, [], [{max_queue, 5000}]).

%% @doc Start UDP worker
start_link(I) ->
    ?GEN_SERVER:start_link({local, get_proc(I)}, ?MODULE, [],
			   [{max_queue, 5000}]).

%% @doc Start TCP acceptor
start_link(Sock, Opts) ->
    ?GEN_SERVER:start_link(?MODULE, [Sock, Opts], [{max_queue, 5000}]).

%% @doc Start TCP client to connect, the callback
start() ->
    supervisor:start_child(esip_tcp_sup, []).

socket_type() ->
    raw.

start({gen_tcp, Sock}, Opts) ->
    supervisor:start_child(esip_tcp_sup, [Sock, Opts]).

%% @doc TCP connect
connect(Addrs) ->
    connect(Addrs, []).

%% @doc first is UDP connect, second is TCP
connect([AddrPort|_Addrs], #sip_socket{} = Sock) ->
    {ok, Sock#sip_socket{peer = AddrPort}};
connect(Addrs, Opts) when is_list(Opts) ->
    case start() of
        {ok, Pid} ->
            ?GEN_SERVER:call(Pid, {connect, Addrs, Opts}, 60000);
        Err ->
            Err
    end.

%% @doc TCP send
send(Sock, Data) ->
    gen_tcp:send(Sock, Data).

%% @doc UDP send
send(Sock, {Addr, Port}, Data) ->
    NewAddr = case Addr of
                  {A, B, C, D} ->
                      case inet:sockname(Sock) of
                          {ok, {{_, _, _, _, _, _, _, _}, _}} ->
                              {0, 0, 0, 0, 0, 16#ffff,
                               (A bsl 8) bor B, (C bsl 8) bor D};
                          _ ->
                              Addr
                      end;
                  {0, 0, 0, 0, 0, 16#ffff, X, Y} ->
                      case inet:sockname(Sock) of
                          {ok, {{_, _, _, _}, _}} ->
                              <<A, B, C, D>> = <<X:16, Y:16>>,
                              {A, B, C, D};
                          _ ->
                              Addr
                      end;
                  _ ->
                      Addr
              end,
    gen_udp:send(Sock, NewAddr, Port, Data).

tcp_init(ListenSock, Opts) ->
    {ok, {IP, Port}} = inet:sockname(ListenSock),
    ViaHost = get_via_host(IP, Opts),
    esip_transport:register_route(tcp, ViaHost, Port).

udp_init(Sock, Opts) ->
    {ok, {IP, Port}} = inet:sockname(Sock),
    ViaHost = get_via_host(IP, Opts),
    esip_transport:register_route(udp, ViaHost, Port),
    lists:foreach(
      fun(I) ->
	      Pid = get_proc(I),
	      Pid ! {init, Sock}
      end, lists:seq(1, get_pool_size())).

udp_recv(Sock, Addr, Port, Data, _Opts) ->
    Pid = get_proc_by_hash({Addr, Port}),
    Pid ! {udp, Sock, Addr, Port, Data}.

start_pool() ->
    try
	lists:foreach(
	  fun(I) ->
		  Spec = {get_proc(I),
			  {?MODULE, start_link, [I]},
			  permanent, brutal_kill, worker,
			  [?MODULE]},
		  {ok, _} = supervisor:start_child(esip_udp_sup, Spec)
	  end, lists:seq(1, get_pool_size()))
    catch error:{badmatch, {error, _} = Err} ->
	    ?ERROR_MSG("failed to start UDP pool: ~p", [Err]),
	    Err
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    MaxSize = esip:get_config_value(max_msg_size),
    {ok, #state{max_size = MaxSize}};
init([Sock, _Opts]) ->
    case inet:peername(Sock) of
	{ok, Peer} ->
	    case inet:sockname(Sock) of
		{ok, MyAddr} ->
		    inet:setopts(Sock, [{active, once}]),
		    MaxSize = esip:get_config_value(max_msg_size),
		    {ok, #state{max_size = MaxSize,
				sock = Sock,
				peer = Peer,
				addr = MyAddr,
				type = tcp}};
		{error, Err} ->
		    {stop, Err}
	    end;
	{error, Err} ->
	    {stop, Err}
    end.

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

handle_info({udp, UDPSock, IP, Port, Data}, State) ->
    SIPSock = #sip_socket{type = udp, sock = UDPSock,
                          addr = State#state.addr,
			  peer = {IP, Port}},
    esip:callback(data_in, [Data, SIPSock]),
    datagram_transport_recv(SIPSock, Data),
    {noreply, State};
handle_info({init, UDPSock}, State) ->
    {ok, MyAddr} = inet:sockname(UDPSock),
    SIPSock = #sip_socket{type = udp, sock = UDPSock, addr = MyAddr},
    esip_transport:register_udp_listener(SIPSock),
    {noreply, State#state{addr = MyAddr}};
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
    case gen_tcp:connect(Addr, Port, connect_opts()) of
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
            stream_transport_recv(NewState, Msg#sip{body = Body}),
            process_data(NewState, <<>>);
        _ when size(NewBuf) < MaxSize ->
            {noreply, State#state{buf = NewBuf}};
        _ ->
            {stop, normal, State}
    end.

stream_transport_recv(State, Msg) ->
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

datagram_transport_recv(SIPSock, Data) ->
    case catch esip_codec:decode(Data) of
        {ok, #sip{hdrs = Hdrs, body = Body} = Msg} ->
            case esip:get_hdr('content-length', Hdrs) of
                N when is_integer(N), N >= 0 ->
                    case Body of
                        <<_:N/binary>> ->
                            do_transport_recv(SIPSock, Msg);
                        <<Body1:N/binary, _/binary>> ->
                            do_transport_recv(SIPSock, Msg#sip{body = Body1});
                        _ ->
                            ok
                    end;
                _ ->
                    do_transport_recv(SIPSock, Msg)
            end;
	Err ->
	    Err
    end.

do_transport_recv(SIPSock, Msg) ->
    case catch esip_transport:recv(SIPSock, Msg) of
        {'EXIT', Reason} ->
            ?ERROR_MSG("transport layer failed:~n"
                       "** Packet: ~p~n** Reason: ~p",
                       [Msg, Reason]);
        _ ->
            ok
    end.

connect_opts() ->
    SendOpts = try erlang:system_info(otp_release) >= "R13B"
	       of
		   true -> [{send_timeout_close, true}];
		   false -> []
	       catch
		   _:_ -> []
	       end,
    [binary,
     {active, once},
     {packet, 0},
     {send_timeout, ?TCP_SEND_TIMEOUT}
     | SendOpts].

get_pool_size() ->
    100.

get_proc_by_hash(Source) ->
    N = erlang:phash2(Source, get_pool_size()) + 1,
    get_proc(N).

get_proc(N) ->
    list_to_atom("esip_udp_" ++ integer_to_list(N)).

get_via_host(IP, Opts) ->
    case proplists:get_value(via_host, Opts, <<"">>) of
	ViaHost when is_binary(ViaHost), ViaHost /= <<"">> ->
	    ViaHost;
	_ ->
	    case lists:sum(tuple_to_list(IP)) of
		0 ->
		    undefined;
		_ ->
		    iolist_to_binary(inet_parse:ntoa(IP))
	    end
    end.
