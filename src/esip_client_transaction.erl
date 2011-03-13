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
-export([start_link/2, start/2, start/3, stop/1, route/2, cancel/2]).

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

-record(state, {req, tu, sock, trid, branch, cancelled = false}).

%%%===================================================================
%%% API
%%%===================================================================
start_link(TU, SIPSocket) ->
    gen_fsm:start_link(?MODULE, [TU, SIPSocket], []).

start(Request, TU) ->
    start(Request, TU, undefined).

start(Request, TU, SIPSocket) ->
    case supervisor:start_child(esip_client_transaction_sup,
                                [TU, SIPSocket]) of
        {ok, Pid} ->
            gen_fsm:send_event(Pid, Request),
            {ok, #trid{owner = Pid, type = client}};
        Err ->
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
init([TU, SIPSocket]) ->
    TrID = #trid{owner = self(), type = client},
    {ok, trying, #state{tu = TU, trid = TrID, sock = SIPSocket}}.

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
            esip_transport:send(SIPSock, NewRequest),
            {next_state, trying, State#state{sock = SIPSock, req = NewRequest,
                                             branch = Branch}};
        Err ->
            pass_to_transaction_user(State#state{req = Request}, Err),
            {stop, normal, State}
    end;
trying({timer_A, T}, State) ->
    esip_transport:send(State#state.sock, State#state.req),
    gen_fsm:send_event_after(2*T, {timer_A, 2*T}),
    {next_state, trying, State};
trying({timer_E, T}, State) ->
    esip_transport:send(State#state.sock, State#state.req),
    T4 = esip:timer4(),
    case 2*T < T4 of
        true ->
            gen_fsm:send_event_after(2*T, {timer_E, 2*T});
        false ->
            gen_fsm:send_event_after(T4, {timer_E, T4})
    end,
    {next_state, trying, State};
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
    send_ack(State, Resp),
    if (State#state.sock)#sip_socket.type == udp ->
            gen_fsm:send_event_after(64*esip:timer1(), timer_D),
            {next_state, completed, State};
       true ->
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
    esip_transport:send(State#state.sock, State#state.req),
    gen_fsm:send_event_after(esip:timer2(), {timer_E, T}),
    {next_state, proceeding, State};
proceeding(timer_F, State) ->
    pass_to_transaction_user(State, {error, timeout}),
    {stop, normal, State};
proceeding({cancel, TU}, #state{req = #sip{hdrs = Hdrs} = Req} = State) ->
    NewHdrs = esip:filter_hdrs(['call-id', to, from, cseq,
                                'max-forwards', 'route'], Hdrs),
    [Via|_] = esip:get_hdrs(via, Hdrs),
    CancelReq = #sip{type = request,
                     method = <<"CANCEL">>,
                     uri = Req#sip.uri,
                     hdrs = [{via, [Via]}|NewHdrs]},
    esip_client_transaction:start(CancelReq, TU, State#state.sock),
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
    send_ack(State, Resp),
    {next_state, completed, State};
completed(_Event, State) ->
    {next_state, completed, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

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
pass_to_transaction_user(#state{trid = TrID, tu = TU, req = Req}, Resp) ->
    case TU of
        F when is_function(F) ->
            F(Resp, Req, TrID);
        {M, F, A} ->
            apply(M, F, [Resp, Req, TrID | A])
    end.

send_ack(#state{req = #sip{uri = URI, hdrs = Hdrs,
                           method = <<"INVITE">>}} = State, Resp) ->
    {Hdrs1, _} = esip:split_hdrs(['call-id', from, cseq,
                                  route, 'max-forwards'], Hdrs),
    To = esip:get_hdr(to, Resp#sip.hdrs),
    [Via|_] = esip:get_hdrs(via, Hdrs),
    ACK = #sip{type = request,
               uri = URI,
               method = <<"ACK">>,
               hdrs = [{via, [Via]},{to, To}|Hdrs1]},
    esip_transport:send(State#state.sock, ACK);
send_ack(_, _) ->
    ok.

connect(#state{sock = undefined}, #sip{uri = URI, hdrs = Hdrs} = Req) ->
    NewURI = case esip:get_hdrs(route, Hdrs) of
                 [{_, RouteURI, _}|_] ->
                     RouteURI;
                 _ ->
                     URI
             end,
    VHost = case esip:get_hdr(from, Hdrs) of
                {_, #uri{host = Host}, _} ->
                    Host;
                _ ->
                    undefined
            end,
    case esip_transport:connect(NewURI, VHost) of
        {ok, SIPSocket} ->
            Branch = esip:make_branch(),
            NewHdrs = [esip_transport:make_via_hdr(VHost, Branch)|Hdrs],
            {ok, SIPSocket, Req#sip{hdrs = NewHdrs}, Branch};
        Err ->
            Err
    end;
connect(#state{sock = SIPSocket}, #sip{method = <<"CANCEL">>, hdrs = Hdrs} = Req) ->
    {[{via, [Via|_]}|_], TailHdrs} = esip:split_hdrs([via], Hdrs),
    Branch = esip:get_param(<<"branch">>, Via#via.params),
    {ok, SIPSocket, Req#sip{hdrs = [{via, [Via]}|TailHdrs]}, Branch};
connect(#state{sock = SIPSocket}, #sip{hdrs = Hdrs} = Req) ->
    VHost = case esip:get_hdr(from, Hdrs) of
                {_, #uri{host = Host}, _} ->
                    Host;
                _ ->
                    undefined
            end,
    Branch = esip:make_branch(),
    NewHdrs = [esip_transport:make_via_hdr(VHost, Branch)|Hdrs],
    {ok, SIPSocket, Req#sip{hdrs = NewHdrs}, Branch}.
