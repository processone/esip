%%%-------------------------------------------------------------------
%%% File    : esip_server_transaction.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Server transaction layer. See RFC3261 and friends.
%%%
%%% Created : 15 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_server_transaction).

-behaviour(gen_fsm).

%% API
-export([start_link/2, start/2, stop/1, route/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4,
	 handle_info/3, terminate/3, code_change/4]).

%% gen_fsm states
-export([trying/2,
	 proceeding/2,
         accepted/2,
	 completed/2,
         confirmed/2]).

-include("esip.hrl").
-include("esip_lib.hrl").

-define(MAX_TRANSACTION_LIFETIME, timer:minutes(5)).

-record(state, {sock, branch, req, resp, tu, trid}).

%%====================================================================
%% API
%%====================================================================
start_link(SIPSocket, Request) ->
    gen_fsm:start_link(?MODULE, [SIPSocket, Request], []).

start(SIPSocket, Request) ->
    case supervisor:start_child(esip_server_transaction_sup,
                                [SIPSocket, Request]) of
        {ok, Pid} ->
            {ok, #trid{owner = Pid, type = server}};
        Err ->
            Err
    end.

route(Pid, R) ->
    gen_fsm:send_event(Pid, R).

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
init([SIPSock, Request]) ->
    Branch = esip:get_branch(Request#sip.hdrs),
    TrID = #trid{owner = self(), type = server},
    State = #state{sock = SIPSock, branch = Branch, trid = TrID},
    gen_fsm:send_event(self(), Request),
    esip_transaction:insert(Branch, Request#sip.method, server, self()),
    erlang:send_after(?MAX_TRANSACTION_LIFETIME, self(), stop),
    {ok, trying, State}.

trying(#sip{method = <<"CANCEL">>, type = request} = Req, State) ->
    Resp = esip:make_response(Req,
                              #sip{type = response, status = 200},
                              esip:make_tag()),
    proceeding(Resp, State#state{req = Req});
trying(#sip{type = request, method = Method} = Req, State) ->
    {TU, ErrorStatus} = find_transaction_user(Req),
    case is_transaction_user(TU) of
        true ->
            NewState = State#state{tu = TU, req = Req},
            case pass_to_transaction_user(NewState, Req) of
                #sip{type = response} = Resp ->
                    proceeding(Resp, NewState);
                wait ->
                    if Method == <<"INVITE">> ->
                            gen_fsm:send_event_after(200, trying);
                       true ->
                            ok
                    end,
                    {next_state, proceeding, NewState};
                _ ->
                    Resp = esip:make_response(
                             Req, #sip{status = ErrorStatus, type = response},
                             esip:make_tag()),
                    proceeding(Resp, NewState)
            end;
        false ->
            Resp = esip:make_response(
                     Req, #sip{status = ErrorStatus, type = response},
                     esip:make_tag()),
            proceeding(Resp, State#state{req = Req})
    end;
trying(_Event, State) ->
    {next_state, trying, State}.

proceeding(trying, #state{resp = undefined} = State) ->
    %% TU didn't respond in 200 ms
    Resp = esip:make_response(State#state.req,
                              #sip{type = response, status = 100}),
    esip_transport:send(State#state.sock, Resp),
    {next_state, proceeding, State#state{resp = Resp}};
proceeding(#sip{type = response, status = Status} = Resp, State) when Status < 200 ->
    esip_transport:send(State#state.sock, Resp),
    {next_state, proceeding, State#state{resp = Resp}};
proceeding(#sip{type = response, status = Status} = Resp,
           #state{req = #sip{method = <<"INVITE">>}} = State) when Status < 300 ->
    esip_transport:send(State#state.sock, Resp),
    gen_fsm:send_event_after(64*esip:timer1(), timer_L),
    {next_state, accepted, State#state{resp = Resp}};
proceeding(#sip{type = response, status = Status} = Resp,
           #state{req = #sip{method = <<"INVITE">>}} = State) when Status >= 300 ->
    esip_transport:send(State#state.sock, Resp),
    T1 = esip:timer1(),
    if (State#state.sock)#sip_socket.type == udp ->
            gen_fsm:send_event_after(T1, {timer_G, T1});
       true ->
            ok
    end,
    gen_fsm:send_event_after(64*T1, timer_H),
    {next_state, completed, State#state{resp = Resp}};
proceeding(#sip{type = response, status = Status} = Resp, State) when Status >= 200 ->
    esip_transport:send(State#state.sock, Resp),
    if (State#state.sock)#sip_socket.type == udp ->
            gen_fsm:send_event_after(64*esip:timer1(), timer_J),
            {next_state, completed, State#state{resp = Resp}};
       true ->
            {stop, normal, State}
    end;
proceeding(#sip{type = request, method = <<"CANCEL">>} = Req, State) ->
    if (State#state.req)#sip.method == <<"INVITE">> ->
            case pass_to_transaction_user(State, Req) of
                #sip{type = response} = Resp ->
                    proceeding(Resp#sip{method = <<"INVITE">>}, State);
                wait ->
                    {next_state, proceeding, State}
            end;
       true ->
            {next_state, proceeding, State}
    end;
proceeding(#sip{type = request, method = Method},
           #state{req = Req, resp = Resp} = State) ->
    case Req#sip.method of
	Method when Resp /= undefined ->
            esip_transport:send(State#state.sock, Resp),
            {next_state, proceeding, State};
	_ ->
	    {next_state, proceeding, State}
    end;
proceeding(_Event, State) ->
    {next_state, proceeding, State}.

accepted(#sip{type = request, method = <<"ACK">>} = Req, State) ->
    pass_to_transaction_user(State, Req),
    {next_state, accepted, State};
accepted(#sip{type = response, status = Status} = Resp, State)
  when Status >= 200, Status < 300 ->
    esip_transport:send(State#state.sock, Resp),
    {next_state, accepted, State};
accepted(timer_L, State) ->
    {stop, normal, State};
accepted(_Event, State) ->
    {next_state, accepted, State}.

completed(#sip{type = request, method = <<"ACK">>},
          #state{req = #sip{method = <<"INVITE">>}} = State) ->
    if (State#state.sock)#sip_socket.type == udp ->
            gen_fsm:send_event_after(esip:timer4(), timer_I),
            {next_state, confirmed, State};
       true ->
            {stop, normal, State}
    end;
completed(#sip{type = request, method = Method},
          #state{req = Req, resp = Resp} = State) ->
    case Req#sip.method of
	Method ->
            esip_transport:send(State#state.sock, Resp),
            {next_state, completed, State};
	_ ->
	    {next_state, completed, State}
    end;
completed(timer_H, State) ->
    %% TODO: notify TU about a failure
    {stop, normal, State};
completed({timer_G, T}, State) ->
    esip_transport:send(State#state.sock, State#state.resp),
    T2 = esip:timer2(),
    case 2*T < T2 of
        true ->
            gen_fsm:send_event_after(2*T, {timer_G, 2*T});
        false ->
            gen_fsm:send_event_after(T2, {timer_G, T2})
    end,
    {next_state, completed, State};
completed(timer_J, State) ->
    {stop, normal, State};
completed(_Event, State) ->
    {next_state, completed, State}.

confirmed(timer_I, State) ->
    {stop, normal, State};
confirmed(_Event, State) ->
    {next_state, confirmed, State}.

handle_event(stop, _StateName, State) ->
    {stop, normal, State};
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ok, StateName, State}.

handle_info(stop, _StateName, State) ->
    {stop, normal, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, #state{branch = Branch, req = Req}) ->
    esip_transaction:delete(Branch, Req#sip.method, server).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
is_transaction_user(#sip{type = response}) ->
    true;
is_transaction_user(TU) ->
    is_function(TU) orelse (is_tuple(TU) andalso (tuple_size(TU) == 3)).

pass_to_transaction_user(#state{trid = TrID, tu = TU}, Req) ->
    case TU of
        F when is_function(F) ->
            esip:callback(F, [Req, TrID]);
        {M, F, A} ->
            esip:callback(M, F, [Req, TrID | A]);
        #sip{type = response} = Resp ->
            Resp
    end.

find_transaction_user(Req) ->
    case esip_dialog:id(uas, Req) of
        #dialog_id{local_tag = Tag} when Tag /= <<>> ->
            case esip_dialog:lookup(esip_dialog:id(uas, Req)) of
                {ok, TU, #dialog{remote_seq_num = RemoteSeqNum}} ->
                    CSeq = esip:get_hdr(cseq, Req#sip.hdrs),
                    if is_integer(RemoteSeqNum), RemoteSeqNum > CSeq ->
                            {stop, 500};
                       true ->
                            {TU, 500}
                    end;
                _ ->
                    {esip:callback(transaction_user, [Req]), 500}
            end;
        _ ->
            {esip:callback(transaction_user, [Req]), 500}
    end.
