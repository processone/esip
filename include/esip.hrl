%%%----------------------------------------------------------------------
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
              hdrs = []}).

-record(via, {proto = <<"SIP">>,
              version = {2,0},
              transport,
              host,
              port = undefined,
              params = []}).

-record(dialog_id, {'call-id', remote_tag, local_tag}).

-record(sip_socket, {type :: udp | tcp | tls,
		     sock :: inet:socket() | fast_tls:tls_socket(),
		     addr :: {inet:ip_address(), inet:port_number()},
		     peer :: {inet:ip_address(), inet:port_number()},
		     pid  :: pid()}).
