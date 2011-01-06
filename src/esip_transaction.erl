%%%-------------------------------------------------------------------
%%% File    : esip_transaction.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Route client/server transactions
%%%
%%% Created : 15 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_transaction).

-behaviour(gen_server).

%% API
-export([start_link/0, process/2, response/2, cancel/2,
         request/2, insert/3, delete/2, lookup/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").

-record(state, {}).

%%====================================================================
%% API
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

process(SIPSock, #sip{method = Method, hdrs = Hdrs, type = request} = Req) ->
    Branch = esip:get_branch(Hdrs),
    case lookup(transaction_key(Branch, Method)) of
	{ok, Pid} ->
	    esip_server_transaction:route(Pid, Req);
        error when Method == <<"ACK">> ->
            case esip_dialog:lookup(esip_dialog:id(uas, Req)) of
                {ok, Core, _} ->
                    pass_to_core(Core, Req);
                _Err ->
                    esip:callback(request, [Req, undefined])
            end;
	error when Method == <<"CANCEL">> ->
            case lookup(Branch) of
                {ok, Pid} ->
                    esip_server_transaction:route(Pid, Req),
                    esip_server_transaction:start(SIPSock, Req);
                error ->
                    case esip:callback(request, [Req, undefined]) of
                        #sip{type = response} = Resp ->
                            esip_transport:send(SIPSock, Resp);
                        pass ->
                            ok;
                        _ ->
                            Resp = esip:make_response(
                                     Req,
                                     #sip{type = response, status = 481},
                                     esip:make_tag()),
                            esip_transport:send(SIPSock, Resp)
                    end
            end;
        error ->
            esip_server_transaction:start(SIPSock, Req)
    end;
process(_SIPSock, #sip{method = Method, hdrs = Hdrs, type = response} = Resp) ->
    Branch = esip:get_branch(Hdrs),
    case lookup(transaction_key(Branch, Method)) of
        {ok, Pid} ->
            esip_client_transaction:route(Pid, Resp);
        _ ->
            esip:callback(response, [Resp])
    end.

response(#trid{owner = Pid, type = server}, #sip{type = response} = Resp) ->
    esip_server_transaction:route(Pid, Resp);
response(#sip{method = Method, type = request, hdrs = Hdrs},
         #sip{type = response} = Resp) ->
    Branch = esip:get_branch(Hdrs),
    case lookup(transaction_key(Branch, Method)) of
        {ok, Pid} ->
            esip_server_transaction:route(Pid, Resp);
        error ->
            ok
    end;
response(_, _) ->
    ok.

request(#sip{type = request} = Req, TU) ->
    esip_client_transaction:start(Req, TU).

cancel(#trid{type = client, owner = Pid}, TU) ->
    esip_client_transaction:cancel(Pid, TU).

insert(Branch, Method, Pid) ->
    ets:insert(?MODULE, {transaction_key(Branch, Method), Pid}).

delete(Branch, Method) ->
    ets:delete(?MODULE, transaction_key(Branch, Method)).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    ets:new(?MODULE, [public, named_table]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, bad_request, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
lookup(TransactionKey) ->
    case ets:lookup(?MODULE, TransactionKey) of
	[{_, Pid}] ->
	    {ok, Pid};
	_ ->
	    error
    end.

transaction_key(Branch, <<"CANCEL">>) ->
    {Branch, cancel};
transaction_key(Branch, _Method) ->
    Branch.

pass_to_core(Core, Req) ->
    case Core of
        F when is_function(F) ->
            F(Req, undefined);
        {M, F, A} ->
            apply(M, F, [Req, undefined | A])
    end.
