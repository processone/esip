%%%-------------------------------------------------------------------
%%% File    : test.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description :
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(test).

-behaviour(esip).

-export([start/0, init/0, dialog_request/2, response/3, transaction/2]).

%% esip callbacks
-export([transaction_user/1, data_in/4, data_out/4,
         message_in/4, message_out/4,
         response/1, request/2]).

-include("esip.hrl").

-define(VERSION, <<"esip/0.1">>).
-define(ALLOW, [<<"INVITE">>, <<"OPTIONS">>,
                <<"CANCEL">>, <<"ACK">>, <<"BYE">>]).

start() ->
    spawn(?MODULE, init, []).

init() ->
    register(?MODULE, self()),
    esip:start(?MODULE, [{listen, 5090, udp, [{ip, {192,168,1,1}}]},
                         {listen, 5090, tcp, [{ip, {192,168,1,1}}]},
                         {hostname, "zinid.ru"}]),
    %%self() ! options,
    self() ! invite,
    loop().

%%%-------------------------------------------------------------------
%%% esip callbacks
%%%-------------------------------------------------------------------
data_in(Transport, From, To, Data) ->
    log(Transport, From, To, Data).

data_out(Transport, From, To, Data) ->
    log(Transport, From, To, Data).

message_in(_, _, _, _) ->
    ok.

message_out(#sip{hdrs = Hdrs, type = Type, method = Method} = Msg,
            Transport, _, _) ->
    Hdrs1 = case Type of
                response ->
                    esip:set_hdr(server, ?VERSION, Hdrs);
                request ->
                    esip:set_hdr('user-agent', ?VERSION, Hdrs)
            end,
    Hdrs2 = if Type == request, Method == <<"INVITE">> ->
                    esip:set_hdr(contact, esip:make_contact(Transport), Hdrs1);
               true ->
                    Hdrs1
            end,
    Msg#sip{hdrs = Hdrs2}.

response(_) ->
    ok.

request(_, _) ->
    ok.

transaction_user(_Req) ->
    {?MODULE, transaction, []}.

%%%-------------------------------------------------------------------
%%% internal functions
%%%-------------------------------------------------------------------
log(Transport, {FromIP, FromPort}, {ToIP, ToPort}, Data) ->
    error_logger:info_msg(
      "** SIP [~p] ~s:~p -> ~s:~p:~n~s",
      [Transport, inet_parse:ntoa(FromIP), FromPort,
       inet_parse:ntoa(ToIP), ToPort, Data]).

transaction(#sip{type = request, hdrs = Hdrs, method = <<"OPTIONS">>} = Req, _) ->
    Require = esip:get_hdrs(require, Hdrs),
    if Require /= [] ->
            esip:make_response(Req,
                               #sip{status = 420,
                                    type = response,
                                    hdrs = [{require, Require}]},
                               esip:make_tag());
       true ->
            esip:make_response(Req,
                               #sip{status = 200,
                                    type = response,
                                    hdrs = [{allow, ?ALLOW}]},
                               esip:make_tag())
    end;
transaction(#sip{type = request, method = <<"INVITE">>} = Req, _) ->
    Tag = esip:make_tag(),
    case esip:open_dialog(Req, Tag, early, {?MODULE, dialog_request, []}) of
        {ok, _DialogID} ->
            esip:make_response(
              Req, #sip{type = response, status = 180,
                        hdrs = [{require, [<<"100rel">>]},
                                {rseq, esip:make_cseq()}]},
              Tag);
        Err ->
            {Status, Reason} = esip:error_status(Err),
            esip:make_response(
              Req, #sip{status = Status, type = response, reason = Reason},
              Tag)
    end;
transaction(#sip{type = request, method = <<"sINVITE">>,
             hdrs = Hdrs, body = Body} = Req, _) ->
    Tag = esip:make_tag(),
    case esip:open_dialog(Req, Tag, confirmed, {?MODULE, dialog_request, []}) of
        {ok, DialogID} ->
            NewHdrs = esip:filter_hdrs(['content-type'], Hdrs),
            HostName = esip:get_config_value(hostname),
            timer:apply_after(5000, esip, dialog_request,
                              [DialogID,
                               #sip{type = request, method = <<"BYE">>,
                                    hdrs = esip:make_hdrs()},
                               {?MODULE, response, []}]),
            esip:make_response(
              Req,
              #sip{status = 200, type = response, body = Body,
                   hdrs = [{contact, [{<<>>,
                                       #uri{proto = <<"sip">>,
                                            host = HostName,
                                            port = 5090}, []}]}|NewHdrs]},
              Tag);
        Err ->
            {Status, Reason} = esip:error_status(Err),
            esip:make_response(
              Req, #sip{status = Status, type = response, reason = Reason},
              Tag)
    end;
transaction(#sip{type = request, method = <<"CANCEL">>} = Req, _TrID) ->
    esip:make_response(Req,
                       #sip{type = response, status = 487},
                       esip:make_tag());
transaction(#sip{type = request} = Req, _) ->
    esip:make_response(Req,
                       #sip{status = 405,
                            type = response,
                            hdrs = [{allow, ?ALLOW}]},
                       esip:make_tag()).

%% response(#sip{status = 180}, _, TrID) ->
%%     esip:cancel(TrID, fun(_, _, _) -> ok end);
response(#sip{status = Status} = Resp, Req, _) when Status >= 200, Status < 300 ->
    case esip:open_dialog(Req, Resp, uac, {?MODULE, dialog_request, []}) of
        {ok, DialogID} ->
            esip:ack(DialogID);
        _ ->
            ok
    end;
response(_Resp, _, _) ->
    %%io:format("Resp: ~p~n", [_Resp]),
    ok.

dialog_request(#sip{type = request, method = <<"BYE">>} = Req, _TrID) ->
    esip:close_dialog(esip:dialog_id(uas, Req)),
    esip:make_response(Req, #sip{type = response, status = 200});
dialog_request(#sip{type = request, method = <<"ACK">>}, _TrID) ->
    ok.

loop() ->
    ToURI = #uri{proto = <<"sip">>,
                 user = <<"xram">>,
                 host = <<"192.168.1.1">>,
                 params = []},
    FromURI = #uri{proto = <<"sip">>,
                   user = <<"zinid">>,
                   host = <<"192.168.1.1">>,
                   port = 5090},
    Hdrs = [{to, {<<>>, ToURI, []}},
            {from, {<<>>, FromURI, [{<<"tag">>, esip:make_tag()}]}}
            |esip:make_hdrs()],
    receive
        invite ->
            Req = #sip{type = request,
                       method = <<"INVITE">>,
                       uri = ToURI,
                       hdrs = [{'content-type', {<<"application/sdp">>, []}}|Hdrs],
                       body = <<"v=0\n"
                                "o=esip 745407524 1045017468 IN IP4 192.168.1.1\n"
                                "s=-\n"
                                "c=IN IP4 192.168.1.1\n"
                                "t=0 0\n"
                                "m=audio 8000 RTP/AVP 98 97 8 0 3 101\n"
                                "a=rtpmap:98 speex/16000\n"
                                "a=rtpmap:97 speex/8000\n"
                                "a=rtpmap:8 PCMA/8000\n"
                                "a=rtpmap:0 PCMU/8000\n"
                                "a=rtpmap:3 GSM/8000\n"
                                "a=rtpmap:101 telephone-event/8000\n"
                                "a=fmtp:101 0-15\n"
                                "a=ptime:20\n">>},
            esip:request(Req, {?MODULE, response, []}),
            loop();
        options ->
            Req = #sip{type = request,
                       method = <<"OPTIONS">>,
                       uri = ToURI,
                       hdrs = esip:set_hdr('max-forwards', 0, Hdrs)},
            esip:request(Req, {?MODULE, response, []}),
            loop();
        _ ->
	    loop()
    end.
