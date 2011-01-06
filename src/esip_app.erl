%%%-------------------------------------------------------------------
%%% File    : esip_app.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : SIP application
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% Application callbacks
%%====================================================================
start(_Type, _StartArgs) ->
    case esip_sup:start_link() of
	{ok, Pid} -> 
	    {ok, Pid};
	Error ->
	    Error
    end.

stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
