%%%----------------------------------------------------------------------
%%% File    : esip_sup.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : SIP supervisor
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% Copyright (C) 2002-2017 ProcessOne, SARL. All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%%----------------------------------------------------------------------

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
    ESIP = {esip, {esip, start_link, []},
	    permanent, 2000, worker, [esip]},
    Listener = {esip_listener, {esip_listener, start_link, []},
		permanent, 2000, worker, [esip_listener]},
    Dialog =
        {esip_dialog, {esip_dialog, start_link, []},
	 permanent, 2000, worker, [esip_dialog]},
    Transaction =
	{esip_transaction, {esip_transaction, start_link, []},
	 permanent, 2000, worker, [esip_transaction]},
    Transport =
        {esip_transport, {esip_transport, start_link, []},
	 permanent, 2000, worker, [esip_transport]},
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
    TCPConnectionSup =
        {esip_tcp_sup,
         {esip_tmp_sup, start_link,
          [esip_tcp_sup, esip_socket]},
         permanent,
         infinity,
         supervisor,
         [esip_tmp_sup]},
    UDPConnectionSup =
        {esip_udp_sup,
         {esip_udp_sup, start_link, []},
         permanent,
         infinity,
         supervisor,
         [esip_udp_sup]},
    {ok,{{one_for_one,10,1},
	 [ESIP,
	  Listener,
	  Dialog,
	  ServerTransactionSup,
	  ClientTransactionSup,
	  Transaction,
          Transport,
          TCPConnectionSup,
          UDPConnectionSup]}}.

%%====================================================================
%% Internal functions
%%====================================================================
