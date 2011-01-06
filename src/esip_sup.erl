%%%-------------------------------------------------------------------
%%% File    : esip_sup.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Top supervisor
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    Dialog =
        {esip_dialog, {esip_dialog, start_link, []},
	 permanent, 2000, worker, [esip_dialog]},
    Transaction =
	{esip_transaction, {esip_transaction, start_link, []},
	 permanent, 2000, worker, [esip_transaction]},
    ServerTransactionSup =
	{esip_server_transaction_sup,
	 {esip_tmp_sup, start_link,
	  [esip_server_transaction_sup, esip_server_transaction]},
	 permanent,
	 infinity,
	 supervisor,
	 [esip_tmp_sup]},
    ClientTransactionSup =
	{esip_client_transaction_sup,
	 {esip_tmp_sup, start_link,
	  [esip_client_transaction_sup, esip_client_transaction]},
	 permanent,
	 infinity,
	 supervisor,
	 [esip_tmp_sup]},
    {ok,{{one_for_one,10,1},
	 [Dialog,
	  ServerTransactionSup,
	  ClientTransactionSup,
	  Transaction]}}.

%%====================================================================
%% Internal functions
%%====================================================================
