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
	error_logger:error_msg("(~p:~p:~p) " ++ Format,
			       [self(), ?MODULE, ?LINE | Args])).

-define(INFO_MSG(Format, Args),
	error_logger:info_msg("(~p:~p:~p) " ++ Format,
			       [self(), ?MODULE, ?LINE | Args])).
