%%%-------------------------------------------------------------------
%%% File    : esip_transport.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Transport layer
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_transport).

%% API
-export([recv/2, send/1, send/2, connect/1, type/1]).

-include("esip.hrl").
-include("esip_lib.hrl").
-include_lib("kernel/include/inet.hrl").

%%====================================================================
%% API
%%====================================================================
recv(#sip_socket{peer = PeerAddr,
                 type = Transport,
                 addr = MyAddr} = SIPSock,
     InRequest) ->
    case esip:callback(message_in, [InRequest, Transport, PeerAddr, MyAddr]) of
        drop ->
            ok;
        Response = #sip{type = response} ->
            send(SIPSock, Response);
        Request = #sip{type = request} ->
            case prepare_request(SIPSock, Request) of
                #sip{} = NewRequest ->
                    esip_transaction:process(SIPSock, NewRequest);
                _ ->
                    ok
            end;
        _ ->
            case prepare_request(SIPSock, InRequest) of
                #sip{} = NewRequest ->
                    esip_transaction:process(SIPSock, NewRequest);
                _ ->
                    ok
            end
    end.

send(#sip_socket{peer = PeerAddr,
                 type = Transport,
                 addr = MyAddr} = SIPSock, Msg) ->
    case esip:callback(message_out, [Msg, Transport, PeerAddr, MyAddr]) of
        drop ->
            ok;
	NewMsg = #sip{} ->
	    do_send(SIPSock, NewMsg);
	_ ->
	    do_send(SIPSock, Msg)
    end.

send(#sip{type = request, uri = URI, hdrs = Hdrs} = Req) ->
    case connect(URI) of
        {ok, #sip_socket{type = Type, addr = {_, Port}} = SIPSock} ->
            Branch = esip:make_branch(),
            NewHdrs = [{via, [#via{transport = esip_transport:type(Type),
                                   host = esip:get_config_value(hostname),
                                   port = Port,
                                   params = [{<<"branch">>, Branch},
                                             {<<"rport">>, <<>>}]}]}|Hdrs],
            send(SIPSock, Req#sip{hdrs = NewHdrs});
        Err ->
            Err
    end.

connect(#uri{host = Host, port = Port}) ->
    case inet:gethostbyname(binary_to_list(Host)) of
        {ok, #hostent{h_addr_list = [Addr|_]}} ->
            NewPort = if is_integer(Port), Port > 0, Port < 65536 ->
                              Port;
                         true ->
                              5060
                      end,
            {ok, #sip_socket{owner = whereis(esip_udp), type = udp,
                             addr = {todo, 5090},
                             peer = {Addr, NewPort}}};
        {error, _} = Err ->
            Err;
        _ ->
            {error, nxdomain}
    end.

type(<<"TLS">>) -> tls;
type(<<"TCP">>) -> tcp;
type(<<"UDP">>) -> udp;
type(<<"SCTP">>) -> sctp;
type(tls) -> <<"TLS">>;
type(tcp) -> <<"TCP">>;
type(udp) -> <<"UDP">>;
type(sctp) -> <<"SCTP">>.

%%====================================================================
%% Internal functions
%%====================================================================
prepare_request(#sip_socket{peer = {Addr, Port}},
                #sip{hdrs = Hdrs, type = Type} = Request) ->
    case esip:split_hdrs([via], Hdrs) of
        {[{_, [#via{params = Params, version = Ver,
                    host = Host} = Via|RestVias]}|Vias], RestHdrs} ->
            case is_valid_via_branch(Params, Ver)
                andalso is_valid_hdrs(RestHdrs, Type) of
                true ->
                    Params1 = case inet_parse:address(
                                     binary_to_list(Host)) of
                                  {ok, Addr} ->
                                      Params;
                                  _ ->
                                      AddrBin = list_to_binary(
                                                  inet_parse:ntoa(Addr)),
                                      esip:set_param(<<"received">>,
                                                     AddrBin,
                                                     Params)
                              end,
                    Params2 = case lists:keysearch(<<"rport">>, 1, Params1) of
                                  {value, {_, <<>>}} ->
                                      esip:set_param(<<"rport">>,
                                                     list_to_binary(
                                                       integer_to_list(Port)),
                                                     Params1);
                                  _ ->
                                      Params1
                              end,
                    NewVias = [{via, [Via#via{params = Params2}|RestVias]}|Vias],
                    Request#sip{hdrs = NewVias ++ RestHdrs};
                false ->
                    error
            end;
        _ ->
            error
    end.

is_valid_hdrs(Hdrs, Type) ->
    try
        From = esip:get_hdr(from, Hdrs),
        To = esip:get_hdr(to, Hdrs),
        CSeq = esip:get_hdr(cseq, Hdrs),
        CallID = esip:get_hdr('call-id', Hdrs),
        MaxForwards = esip:get_hdr('max-forwards', Hdrs),
        has_from(From) and has_to(To)
            and has_max_forwards(MaxForwards, Type)
            and (CSeq /= undefined) and (CallID /= undefined)
    catch _:_ ->
            false
    end.

is_valid_via_branch(Params, Ver) ->
    case esip:get_param(<<"branch">>, Params) of
        <<"z9hG4bK", _/binary>> ->
            true;
        Branch when Branch /= <<>>, Ver /= {2,0} ->
            true;
        _ ->
            false
    end.

has_from({_, #uri{}, _}) -> true;
has_from(_) -> false.

has_to({_, #uri{}, _}) -> true;
has_to(_) -> false.

has_max_forwards(N, request) when is_integer(N) ->
    true;
has_max_forwards(_, response) ->
    true;
has_max_forwards(_, _) ->
    false.

do_send(#sip_socket{type = udp, owner = Pid, peer = Peer}, R) ->
    esip_udp:send(Pid, Peer, R).
