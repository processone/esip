%%%-------------------------------------------------------------------
%%% File    : esip.hrl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : 
%%%
%%% Created : 12 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-record(sip, {type,
              version = {2,0},
              method,
              hdrs = [],
              body = <<>>,
              uri,
              status,
              reason}).

-record(uri, {scheme = <<"sip">>,
              user = <<>>,
              password = <<>>,
              host = <<>>,
              port = undefined,
              params = [],
              headers = []}).

-record(via, {proto = <<"SIP">>,
              version = {2,0},
              transport,
              host,
              port = undefined,
              params = []}).

-record(dialog_id, {'call-id', remote_tag, local_tag}).

-record(sip_socket, {type, sock, addr, peer}).
