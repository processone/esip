%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2011, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  8 Mar 2011 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(proxy).

-behaviour(gen_fsm).
-behaviour(esip).

%% API
-export([start/0, start/1, init/0, route/4, route/5]).

%% esip callbacks
-export([request/3, data_in/2, data_out/2,
         message_in/2, message_out/2,
         response/2, request/2, locate/1]).

%% gen_fsm callbacks
-export([init/1, wait_for_request/2, wait_for_response/2,
         handle_event/3, handle_sync_event/4,
         handle_info/3, terminate/3, code_change/4]).

-include("esip.hrl").

-define(MYNAME, <<"localhost">>).
-define(MYROUTE, <<"localhost">>).
-define(MIN_EXPIRES, 1).
-define(ALLOW, [<<"OPTIONS">>, <<"REGISTER">>]).
-define(DEBUG, true).

-record(state, {opts, orig_trid, orig_req, client_trid}).

%%%===================================================================
%%% API
%%%===================================================================
start() ->
    spawn(?MODULE, init, []).

init() ->
    register(?MODULE, self()),
    Host = binary_to_list(?MYROUTE),
    esip:start(?MODULE, [{listen, 5060, udp, [inet]},
			 {listen, 5060, tcp, [inet]},
			 {route, undefined, tcp, [{host, Host}]},
			 {route, undefined, udp, [{host, Host}]},
			 {max_server_transactions, 50000},
			 {max_client_transactions, 50000}]),
    loop().

start(Opts) ->
    gen_fsm:start(?MODULE, [Opts], []).

route(Resp, Req, _SIPSock, TrID, Pid) ->
    gen_fsm:send_event(Pid, {Resp, Req, TrID}).

route(SIPMsg, _SIPSock, TrID, Pid) ->
    gen_fsm:send_event(Pid, {SIPMsg, TrID}),
    wait.

%%%===================================================================
%%% esip callbacks
%%%===================================================================
-ifdef(DEBUG).
data_in(Data, #sip_socket{type = Transport,
                          addr = {MyIP, MyPort},
                          peer = {PeerIP, PeerPort}}) ->
    error_logger:info_msg(
      "** SIP [~p/in] ~s:~p -> ~s:~p:~n~s",
      [Transport, inet_parse:ntoa(PeerIP), PeerPort,
       inet_parse:ntoa(MyIP), MyPort, Data]).

data_out(Data, #sip_socket{type = Transport,
                           addr = {MyIP, MyPort},
                           peer = {PeerIP, PeerPort}}) ->
    error_logger:info_msg(
      "** SIP [~p/out] ~s:~p -> ~s:~p:~n~s",
      [Transport, inet_parse:ntoa(MyIP), MyPort,
       inet_parse:ntoa(PeerIP), PeerPort, Data]).
-else.
data_in(_, _) ->
    ok.
data_out(_, _) ->
    ok.
-endif.

message_in(#sip{type = request, method = M} = Req, SIPSock)
  when M /= <<"ACK">>, M /= <<"CANCEL">> ->
    case action(Req) of
        {relay, _Opts} ->
            ok;
        Action ->
            request(Req, SIPSock, undefined, Action)
    end;
message_in(_, _) ->
    ok.

message_out(_, _) ->
    ok.

response(Resp, _SIPSock) ->
    case action(Resp) of
        {relay, Opts} ->
            case esip:split_hdrs('via', Resp#sip.hdrs) of
                {[_], _} ->
                    ok;
                {[_|Vias], TailHdrs} ->
                    esip:send(Resp#sip{hdrs = [{'via', Vias}|TailHdrs]}, Opts)
            end;
        _ ->
            ok
    end.

request(#sip{method = <<"ACK">>} = Req, _SIPSock) ->
    case action(Req) of
        {relay, Opts} ->
            esip:send(prepare_request(Req), Opts);
        _ ->
            pass
    end;
request(#sip{method = <<"CANCEL">>} = Req, _SIPSock) ->
    case action(Req) of
        loop ->
            make_response(Req, #sip{status = 483, type = response});
        {unsupported, Require} ->
            make_response(Req, #sip{status = 420,
                                    type = response,
                                    hdrs = [{'unsupported',
                                             Require}]});
        {relay, Opts} ->
            esip:send(prepare_request(Req), Opts),
            pass;
        _ ->
            pass
    end.

request(Req, SIPSock, TrID) ->
    request(Req, SIPSock, TrID, action(Req)).

request(Req, SIPSock, TrID, Action) ->
    case Action of
        to_me ->
            process(Req, SIPSock);
        register ->
            registrar(Req, SIPSock);
        loop ->
            make_response(Req, #sip{status = 483, type = response});
        {unsupported, Require} ->
            make_response(Req, #sip{status = 420,
                                    type = response,
                                    hdrs = [{'unsupported',
                                             Require}]});
        {relay, Opts} ->
            case start(Opts) of
                {ok, Pid} ->
                    route(Req, SIPSock, TrID, Pid),
                    {?MODULE, route, [Pid]};
                Err ->
                    Err
            end;
        proxy_auth ->
            make_response(
              Req,
              #sip{status = 407,
                   type = response,
                   hdrs = [{'proxy-authenticate',
                            make_auth_hdr()}]});
        auth ->
            make_response(
              Req,
              #sip{status = 401,
                   type = response,
                   hdrs = [{'www-authenticate',
                            make_auth_hdr()}]});
        deny ->
            make_response(Req, #sip{status = 403,
                                    type = response});
        not_found ->
            make_response(Req, #sip{status = 480,
                                    type = response})
    end.

action(#sip{type = response, hdrs = Hdrs}) ->
    {_, ToURI, _} = esip:get_hdr('to', Hdrs),
    {_, FromURI, _} = esip:get_hdr('from', Hdrs),
    case {FromURI#uri.host, ToURI#uri.host} of
        {?MYNAME, _} ->
            locate(FromURI);
        {_, ?MYNAME} ->
            locate(FromURI);
        _ ->
            deny
    end;
action(#sip{method = <<"REGISTER">>, type = request, hdrs = Hdrs,
            uri = #uri{user = <<>>, host = ?MYNAME}} = Req) ->
    case esip:get_hdrs('require', Hdrs) of
        [_|_] = Require ->
            {unsupported, Require};
        _ ->
            {_, ToURI, _} = esip:get_hdr('to', Hdrs),
            case ToURI#uri.host of
                ?MYNAME ->
                    case check_auth(Req, 'authorization') of
                        true ->
                            register;
                        false ->
                            auth
                    end;
                _ ->
                    deny
            end
    end;
action(#sip{method = Method, hdrs = Hdrs, type = request} = Req) ->
    case esip:get_hdr('max-forwards', Hdrs) of
        0 when Method == <<"OPTIONS">> ->
            to_me;
        0 ->
            loop;
        _ ->
            case esip:get_hdrs('proxy-require', Hdrs) of
                [_|_] = Require ->
                    {unsupported, Require};
                _ ->
                    {_, ToURI, _} = esip:get_hdr('to', Hdrs),
                    {_, FromURI, _} = esip:get_hdr('from', Hdrs),
                    case {FromURI#uri.host, ToURI#uri.host} of
                        {?MYNAME, _} ->
                            case check_auth(Req, 'proxy-authorization') of
                                true ->
                                    locate(ToURI);
                                false ->
                                    proxy_auth
                            end;
                        {_, ?MYNAME} ->
                            locate(ToURI);
                        _ ->
                            deny
                    end
            end
    end.

check_auth(#sip{method = <<"CANCEL">>}, _) ->
    true;
check_auth(#sip{method = Method, hdrs = Hdrs, body = Body}, AuthHdr) ->
    Issuer = case AuthHdr of
                 'authorization' ->
                     to;
                 'proxy-authorization' ->
                     from
             end,
    {_, #uri{user = User, host = Host}, _} = esip:get_hdr(Issuer, Hdrs),
    case lists:filter(
           fun({_, Params}) ->
                   Username = esip:get_param(<<"username">>, Params),
                   Realm = esip:get_param(<<"realm">>, Params),
                   (User == esip:unquote(Username))
                       and (Host == esip:unquote(Realm))
           end, esip:get_hdrs(AuthHdr, Hdrs)) of
        [{_, Params} = Auth|_] ->
            Username = esip:unquote(esip:get_param(<<"username">>, Params)),
            esip:check_auth(Auth, Method, Body, Username);
        _ ->
            false
    end.

locate(#uri{user = User, host = Host}) ->
    case Host of
        ?MYNAME when User == <<>> ->
            to_me;
        ?MYNAME ->
            case ets:lookup(registrar, {User, ?MYNAME}) of
                [{_, Sock}] ->
                    {relay, [{socket, Sock}]};
                _ ->
                    not_found
            end;
        _ ->
            {relay, []}
    end;
locate(_) ->
    pass.

process(#sip{method = <<"OPTIONS">>} = Req, _) ->
    make_response(Req, #sip{type = response, status = 200,
                            hdrs = [{'allow', ?ALLOW}]});
process(#sip{method = <<"REGISTER">>} = Req, _) ->
    make_response(Req, #sip{type = response, status = 400});
process(Req, _) ->
    make_response(Req, #sip{type = response, status = 405,
                            hdrs = [{'allow', ?ALLOW}]}).

registrar(#sip{hdrs = Hdrs} = Req, SIPSock) ->
    {_, #uri{user = U, host = S}, _} = esip:get_hdr('to', Hdrs),
    AoR = {U, S},
    Expires = esip:get_hdr('expires', Hdrs, 0),
    case esip:get_hdrs('contact', Hdrs) of
        [<<"*">>] when Expires == 0 ->
            ets:delete(registrar, AoR),
            make_response(Req, #sip{type = response, status = 200});
        [{_, _URI, Params}] = Contact ->
            Expires1 = case to_integer(esip:get_param(<<"expires">>, Params),
                                       0, (1 bsl 32)-1) of
                           {ok, Exp} ->
                               Exp;
                           _ ->
                               Expires
                       end,
            if Expires1 >= ?MIN_EXPIRES ->
                    ets:insert(registrar, {AoR, SIPSock}),
                    make_response(Req, #sip{type = response,
                                            status = 200,
                                            hdrs = [{'contact', Contact},
                                                    {'expires', Expires1}]});
               Expires1 > 0, Expires1 < ?MIN_EXPIRES ->
                    make_response(Req, #sip{type = response,
                                            status = 423,
                                            hdrs = [{'min-expires', ?MIN_EXPIRES}]});
               true ->
                    ets:delete(registrar, AoR),
                    make_response(Req, #sip{type = response, status = 200})
            end;
        _ ->
            make_response(Req, #sip{type = response, status = 400})
    end.

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================
init([Opts]) ->
    {ok, wait_for_request, #state{opts = Opts}}.

wait_for_request({#sip{type = request} = Req, TrID}, State) ->
    NewReq = prepare_request(Req),
    case esip:request(NewReq, {?MODULE, route, [self()]}, State#state.opts) of
        {ok, ClientTrID} ->
            {next_state, wait_for_response,
             State#state{orig_trid = TrID,
                         %%orig_req = Req,
                         client_trid = ClientTrID}};
        Err ->
            {Status, Reason} = esip:error_status(Err),
            esip:reply(TrID, make_response(
                               Req, #sip{type = response,
                                         status = Status,
                                         reason = Reason})),
            {stop, normal, State}
    end;
wait_for_request(_Event, State) ->
    {next_state, wait_for_request, State}.

wait_for_response({#sip{method = <<"CANCEL">>, type = request}, _TrID}, State) ->
    esip:cancel(State#state.client_trid),
    {next_state, wait_for_response, State};
wait_for_response({Resp, Req, _TrID}, State) ->
    case Resp of
        {error, _} ->
            {Status, Reason} = esip:error_status(Resp),
            case Status of
                408 when Req#sip.method /= <<"INVITE">> ->
                    %% Absorb useless 408. See RFC4320
                    esip:stop_transaction(State#state.orig_trid);
                _ ->
                    ErrResp = make_response(Req,
                                            #sip{type = response,
                                                 status = Status,
                                                 reason = Reason}),
                    {[_|Vias], Hdrs1} = esip:split_hdrs('via', ErrResp#sip.hdrs),
                    MF = esip:get_hdr('max-forwards', Hdrs1),
                    Hdrs2 = esip:set_hdr('max-forwards', MF+1, Hdrs1),
                    esip:reply(State#state.orig_trid,
                               ErrResp#sip{hdrs = [{'via', Vias}|Hdrs2]})
            end,
            {stop, normal, State};
        #sip{status = 100} ->
            {next_state, wait_for_response, State};
        #sip{status = Status} ->
            case esip:split_hdrs('via', Resp#sip.hdrs) of
                {[_], _} ->
                    {stop, normal, State};
                {[_|Vias], NewHdrs} ->
                    esip:reply(State#state.orig_trid,
                               Resp#sip{hdrs = [{'via', Vias}|NewHdrs]}),
                    if Status < 200 ->
                            {next_state, wait_for_response, State};
                       true ->
                            {stop, normal, State}
                    end
            end
    end;
wait_for_response(_Event, State) ->
    {next_state, wait_for_response, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
loop() ->
    ets:new(registrar, [named_table, public]),
    do_loop().

do_loop() ->
    receive _ -> do_loop() end.

make_auth_hdr() ->
    Realm = ?MYNAME,
    {<<"Digest">>, [{<<"realm">>, esip:quote(Realm)},
                    {<<"qop">>, esip:quote(<<"auth">>)},
                    {<<"nonce">>, esip:quote(esip:make_hexstr(20))}]}.

make_response(Req, Resp) ->
    esip:make_response(Req, Resp, esip:make_tag()).

prepare_request(#sip{hdrs = Hdrs} = Req) ->
    Hdrs1 = case esip:get_hdrs('route', Hdrs) of
                [{_, #uri{host = ?MYROUTE}, _}|Rest] ->
                    if Rest /= [] ->
                            esip:set_hdr('route', Rest, Hdrs);
                       true ->
                            esip:rm_hdr('route', Hdrs)
                    end;
                _ ->
                    Hdrs
            end,
    MF = esip:get_hdr('max-forwards', Hdrs1),
    Hdrs2 = esip:set_hdr('max-forwards', MF-1, Hdrs1),
    Hdrs3 = lists:filter(
              fun({'proxy-authorization', {_, Params}}) ->
                      Realm = esip:get_param(<<"realm">>, Params),
                      ?MYNAME /= esip:unquote(Realm);
                 (_) ->
                      true
              end, Hdrs2),
    RR = [{<<>>, #uri{host = ?MYROUTE, params = [{<<"lr">>, <<>>}]}, []}],
    Req#sip{hdrs = [{'record-route', RR}|Hdrs3]}.

to_integer(Bin, Min, Max) ->
    case catch list_to_integer(binary_to_list(Bin)) of
        N when N >= Min, N =< Max ->
            {ok, N};
        _ ->
            error
    end.
