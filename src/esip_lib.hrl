%%%-------------------------------------------------------------------
%%% File    : esip_lib.hrl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : 
%%%
%%% Created : 15 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-record(sip_socket, {type, owner, sock, peer, addr}).

-record(trid, {owner, type}).

-record(dialog, {secure,
                 route_set,
                 remote_target,
                 remote_seq_num,
                 local_seq_num,
                 'call-id',
                 local_tag,
                 remote_tag,
                 remote_uri,
                 local_uri,
                 state}).

-define(ERROR_MSG(Format, Args),
	error_logger:error_msg("(~p:~p:~p) " ++ Format ++ "~n",
			       [self(), ?MODULE, ?LINE | Args])).

-define(INFO_MSG(Format, Args),
	error_logger:info_msg("(~p:~p:~p) " ++ Format ++ "~n",
			       [self(), ?MODULE, ?LINE | Args])).
