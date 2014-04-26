%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2010, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 20 Dec 2010 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_client_transaction).

-behaviour(gen_fsm).

%% API
-export([start_link/3, start/2, start/3, stop/1, route/2, cancel/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4,
         handle_info/3, terminate/3, code_change/4]).

%% gen_fsm states
-export([trying/2,
         proceeding/2,
         accepted/2,
         completed/2]).

-include("esip.hrl").
-include("esip_lib.hrl").

-define(MAX_TRANSACTION_LIFETIME, timer:minutes(5)).

-record(state, {req, tu, sock, branch, cancelled = false}).

%%%===================================================================
%%% API
%%%===================================================================
start_link(Request, TU, Opts) ->
    gen_fsm:start_link(?MODULE, [Request, TU, Opts], []).

start(Request, TU) ->
    start(Request, TU, []).

start(Request, TU, Opts) ->
    case esip_tmp_sup:start_child(esip_client_transaction_sup,
                                  ?MODULE, gen_fsm, [Request, TU, Opts]) of
        {ok, Pid} ->
            {ok, make_trid(Pid)};
	{error, _} = Err ->
            Err
    end.

route(Pid, R) ->
    gen_fsm:send_event(Pid, R).

cancel(Pid, TU) ->
    gen_fsm:send_event(Pid, {cancel, TU}).

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================
init([Request, TU, Opts]) ->
    SIPSocket = case lists:keysearch(socket, 1, Opts) of
                    {value, {_, S}} -> S;
                    _ -> undefined
                end,
    gen_fsm:send_event(self(), Request),
    erlang:send_after(?MAX_TRANSACTION_LIFETIME, self(), timeout),
    {ok, trying, #state{tu = TU, sock = SIPSocket}}.

trying(#sip{type = request, method = Method} = Request, State) ->
    case connect(State, Request) of
        {ok, #sip_socket{type = Type} = SIPSock, NewRequest, Branch} ->
            esip_transaction:insert(Branch, Method, client, self()),
            T1 = esip:timer1(),
            if Type == udp, Method == <<"INVITE">> ->
                    gen_fsm:send_event_after(T1, {timer_A, T1});
               Type == udp ->
                    gen_fsm:send_event_after(T1, {timer_E, T1});
               true ->
                    ok
            end,
            if Method == <<"INVITE">> ->
                    gen_fsm:send_event_after(64*T1, timer_B);
               true ->
                    gen_fsm:send_event_after(64*T1, timer_F)
            end,
            NewState = State#state{sock = SIPSock, req = NewRequest,
                                   branch = Branch},
            case send(NewState, NewRequest) of
                ok ->
                    {next_state, trying, NewState};
                _ ->
                    {stop, normal, NewState}
            end;
        {error, _} = Err ->
            pass_to_transaction_user(State#state{req = Request}, Err),
            {stop, normal, State}
    end;
trying({timer_A, T}, State) ->
    gen_fsm:send_event_after(2*T, {timer_A, 2*T}),
    case send(State, State#state.req) of
        ok ->
            {next_state, trying, State};
        _ ->
            {stop, normal, State}
    end;
trying({timer_E, T}, State) ->
    T4 = esip:timer4(),
    case 2*T < T4 of
        true ->
            gen_fsm:send_event_after(2*T, {timer_E, 2*T});
        false ->
            gen_fsm:send_event_after(T4, {timer_E, T4})
    end,
    case send(State, State#state.req) of
        ok ->
            {next_state, trying, State};
        _ ->
            {stop, normal, State}
    end;
trying(Timer, State) when Timer == timer_B; Timer == timer_F ->
    pass_to_transaction_user(State, {error, timeout}),
    {stop, normal, State};
trying(#sip{type = response} = Resp, State) ->
    case State#state.cancelled of
        {true, TU} ->
            gen_fsm:send_event(self(), {cancel, TU});
        _ ->
            ok
    end,
    proceeding(Resp, State);
trying({cancel, TU}, State) ->
    {next_state, trying, State#state{cancelled = {true, TU}}};
trying(_Event, State) ->
    {next_state, trying, State}.

proceeding(#sip{type = response, status = Status} = Resp, State) when Status < 200 ->
    pass_to_transaction_user(State, Resp),
    {next_state, proceeding, State};
proceeding(#sip{type = response, status = Status} = Resp,
           #state{req = #sip{method = <<"INVITE">>}} = State) when Status < 300 ->
    pass_to_transaction_user(State, Resp),
    gen_fsm:send_event_after(64*esip:timer1(), timer_M),
    {next_state, accepted, State};
proceeding(#sip{type = response, status = Status} = Resp,
           #state{req = #sip{method = <<"INVITE">>}} = State) when Status >= 300 ->
    pass_to_transaction_user(State, Resp),
    if (State#state.sock)#sip_socket.type == udp ->
            gen_fsm:send_event_after(64*esip:timer1(), timer_D),
            case send_ack(State, Resp) of
                ok ->
                    {next_state, completed, State};
                _ ->
                    {stop, normal, State}
            end;
       true ->
            send_ack(State, Resp),
            {stop, normal, State}
    end;
proceeding(#sip{type = response} = Resp, State) ->
    pass_to_transaction_user(State, Resp),
    if (State#state.sock)#sip_socket.type == udp ->
            gen_fsm:send_event_after(esip:timer4(), timer_K),
            {next_state, completed, State};
       true ->
            {stop, normal, State}
    end;
proceeding({timer_E, T}, State) ->
    gen_fsm:send_event_after(esip:timer2(), {timer_E, T}),
    case send(State, State#state.req) of
        ok ->
            {next_state, proceeding, State};
        _ ->
            {stop, normal, State}
    end;
proceeding(timer_F, State) ->
    pass_to_transaction_user(State, {error, timeout}),
    {stop, normal, State};
proceeding({cancel, TU}, #state{req = #sip{hdrs = Hdrs} = Req} = State) ->
    Hdrs1 = esip:filter_hdrs(['call-id', 'to', 'from', 'cseq',
                              'max-forwards', 'route'], Hdrs),
    [Via|_] = esip:get_hdrs('via', Hdrs),
    Hdrs2 = case esip:get_config_value(software) of
                undefined ->
                    [{'via', [Via]}|Hdrs1];
                UA ->
                    [{'via', [Via]},{'user-agent', UA}|Hdrs1]
            end,
    CancelReq = #sip{type = request,
                     method = <<"CANCEL">>,
                     uri = Req#sip.uri,
                     hdrs = Hdrs2},
    esip_client_transaction:start(CancelReq, TU, [{socket, State#state.sock}]),
    {next_state, proceeding, State};
proceeding(_Event, State) ->
    {next_state, proceeding, State}.

accepted(timer_M, State) ->
    {stop, normal, State};
accepted(#sip{type = response, status = Status} = Resp, State)
  when Status >= 200, Status < 300 ->
    pass_to_transaction_user(State, Resp),
    {next_state, accepted, State};
accepted(_Event, State) ->
    {next_state, accepted, State}.

completed(timer_D, State) ->
    {stop, normal, State};
completed(timer_K, State) ->
    {stop, normal, State};
completed(#sip{type = response, status = Status} = Resp, State) when Status >= 300 ->
    case send_ack(State, Resp) of
        ok ->
            {next_state, completed, State};
        _ ->
            {stop, normal, State}
    end;
completed(_Event, State) ->
    {next_state, completed, State}.

handle_event(stop, _StateName, State) ->
    {stop, normal, State};
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(timeout, _StateName, State) ->
    pass_to_transaction_user(State, {error, timeout}),
    {stop, normal, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, #state{req = Req, branch = Branch}) ->
    if Req /= undefined ->
            catch esip_transaction:delete(Branch, Req#sip.method, client);
       true ->
            ok
    end.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
pass_to_transaction_user(#state{tu = TU, sock = Sock}, Resp) ->
    TrID = make_trid(),
    case TU of
        F when is_function(F) ->
            esip:callback(F, [Resp, Sock, TrID]);
        {M, F, A} ->
            esip:callback(M, F, [Resp, Sock, TrID | A]);
        _ ->
            TU
    end.

send_ack(#state{req = #sip{uri = URI, hdrs = Hdrs,
                           method = <<"INVITE">>}} = State, Resp) ->
    Hdrs1 = esip:filter_hdrs(['call-id', 'from', 'cseq',
                              'route', 'max-forwards',
                              'authorization',
                              'proxy-authorization'], Hdrs),
    To = esip:get_hdr('to', Resp#sip.hdrs),
    [Via|_] = esip:get_hdrs('via', Hdrs),
    Hdrs2 = case esip:get_config_value(software) of
                undefined ->
                    [{'via', [Via]},{'to', To}|Hdrs1];
                Software ->
                    [{'via', [Via]},{'to', To},{'user-agent', Software}|Hdrs1]
            end,
    ACK = #sip{type = request,
               uri = URI,
               method = <<"ACK">>,
               hdrs = Hdrs2},
    send(State, ACK);
send_ack(_, _) ->
    ok.

connect(#state{sock = undefined} = State, Req) ->
    case esip_transport:connect(Req) of
	{ok, SIPSocket} ->
	    connect(State#state{sock = SIPSocket}, Req);
	{error, _} = Err ->
	    Err
    end;
connect(#state{sock = SIPSocket}, #sip{method = <<"CANCEL">>, hdrs = Hdrs} = Req) ->
    {[Via|_], TailHdrs} = esip:split_hdrs('via', Hdrs),
    Branch = esip:get_param(<<"branch">>, Via#via.params),
    {ok, SIPSocket, Req#sip{hdrs = [{'via', [Via]}|TailHdrs]}, Branch};
connect(#state{sock = SIPSocket}, #sip{hdrs = Hdrs} = Req) ->
    Branch = esip:make_branch(Hdrs),
    case esip_transport:make_via_hdr(SIPSocket, Branch) of
	{ok, ViaHdr} ->
	    NewReq = Req#sip{hdrs = [{'via', ViaHdr}|Hdrs]},
	    {ok, SIPSocket, NewReq, Branch};
	{error, _} = Err ->
	    Err
    end.

send(State, Resp) ->
    case esip_transport:send(State#state.sock, Resp) of
        ok ->
            ok;
        {error, _} = Err ->
            pass_to_transaction_user(State, Err),
            Err
    end.

make_trid() ->
    make_trid(self()).

make_trid(Pid) ->
    #trid{owner = Pid, type = client}.
