%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2011, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  9 Jan 2011 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_listener).

-behaviour(gen_server).

%% API
-export([start_link/0, add_listener/3, start_tcp_listener/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("esip_lib.hrl").
-define(TCP_SEND_TIMEOUT, 10000).
-record(state, {listeners = []}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_listener(Port, Transport, Opts) ->
    gen_server:call(?MODULE, {add_listener, Port, Transport, Opts}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    {ok, #state{}}.

handle_call({add_listener, Port, udp, Opts}, _From, State) ->
    case esip_udp:start(Port, Opts) of
        {ok, _Pid} ->
            {reply, ok, State};
        Err ->
            format_listener_error(Port, udp, Opts, Err),
            {reply, Err, State}
    end;
handle_call({add_listener, Port, Transport, Opts}, _From, State)
  when Transport == tls; Transport == tcp ->
    {Pid, Ref} = spawn_monitor(?MODULE, start_tcp_listener,
                               [Port, Opts, self()]),
    receive
        {'DOWN', Ref, _Type, _Object, Info} ->
            Res = {error, Info},
            format_listener_error(Port, Transport, Opts, Res),
            Res;
        {Pid, Res} ->
            case Res of
                {error, _} = Err ->
                    format_listener_error(Port, Transport, Opts, Err);
                ok ->
                    esip_transport:register_route(Transport, Port, Pid)
            end
    end,
    {reply, Res, State};
handle_call({add_listener, Port, Transport, Opts}, _From, State) ->
    Err = {error, eprotonosupport},
    format_listener_error(Port, Transport, Opts, Err),
    {reply, Err, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, _Type, _Pid, _Info}, State) ->
    ?ERROR_MSG("listener failed", []),
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
start_tcp_listener(Port, Opts, Owner) ->
    case gen_tcp:listen(Port, [binary,
                               {packet, 0},
                               {active, false},
                               {reuseaddr, true},
                               {nodelay, true},
                               {send_timeout, ?TCP_SEND_TIMEOUT},
                               {keepalive, true}|Opts]) of
        {ok, ListenSocket} ->
            Owner ! {self(), ok},
            accept(ListenSocket);
        Err ->
            Owner ! {self(), Err}
    end.

accept(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            case {inet:peername(Socket),
                  inet:sockname(Socket)} of
                {{ok, {PeerAddr, PeerPort}}, {ok, {Addr, Port}}} ->
                    ?INFO_MSG("accepted connection: ~s:~p -> ~s:~p",
                              [inet_parse:ntoa(PeerAddr), PeerPort,
                               inet_parse:ntoa(Addr), Port]),
                    case esip_tcp:start(Socket, {PeerAddr, PeerPort},
                                        {Addr, Port}) of
                        {ok, Pid} ->
                            gen_tcp:controlling_process(Socket, Pid);
                        Err ->
                            Err
                    end;
                Err ->
                    ?ERROR_MSG("unable to fetch peername: ~p", [Err]),
                    Err
            end,
            accept(ListenSocket);
        Err ->
            Err
    end.

format_listener_error(Port, Transport, Opts, Err) ->
    ?ERROR_MSG("failed to start listener:~n"
               "** Port: ~p~n"
               "** Transport: ~p~n"
               "** Options: ~p~n"
               "** Reason: ~p",
               [Port, Transport, Opts, Err]).
