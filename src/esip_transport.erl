%%%-------------------------------------------------------------------
%%% File    : esip_transport.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Transport layer
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_transport).

%%-compile(export_all).

%% API
-export([recv/2, send/1, send/2, connect/2, start_link/0,
         register_socket/3, register_socket/4, unregister_socket/3,
         make_via_hdr/0, make_via_hdr/1, make_via_hdr/2,
         register_route/2, register_route/3, unregister_route/2,
         unregister_route/3, resolve/1, make_contact/1, make_contact/0,
         have_route/3, get_route/0, get_route/1, via_transport_to_atom/1]).

-behaviour(gen_server).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").
-include_lib("kernel/include/inet.hrl").

-record(state, {}).

%%====================================================================
%% API
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

recv(#sip_socket{peer = PeerAddr,
                 type = Transport,
                 addr = MyAddr} = SIPSock, #sip{type = OrigType} = Msg) ->
    NewMsg = case esip:callback(message_in,
                                [Msg, Transport, PeerAddr, MyAddr]) of
                 drop -> ok;
                 Msg1 = #sip{} -> Msg1;
                 _ -> Msg
             end,
    case NewMsg of
        #sip{type = request} ->
            case prepare_request(SIPSock, NewMsg) of
                #sip{} = NewRequest ->
                    esip_transaction:process(SIPSock, NewRequest);
                _ ->
                    ok
            end;
        #sip{type = response} when OrigType == request ->
            send(SIPSock, NewMsg);
        #sip{type = response} ->
            case prepare_response(SIPSock, NewMsg) of
                #sip{} = NewResponse ->
                    esip_transaction:process(SIPSock, NewResponse);
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

send(#sip_socket{peer = PeerAddr,
                 type = Transport,
                 addr = MyAddr} = SIPSock, Msg) ->
    NewMsg = case esip:callback(message_out,
                                [Msg, Transport, PeerAddr, MyAddr]) of
                 drop -> ok;
                 Msg1 = #sip{} -> Msg1;
                 _ -> Msg
             end,
    case NewMsg of
        #sip{type = request, hdrs = Hdrs} ->
            NewHdrs = fix_topmost_via(Transport, Hdrs),
            do_send(SIPSock, NewMsg#sip{hdrs = NewHdrs});
        #sip{} ->
            do_send(SIPSock, NewMsg);
        _ ->
            ok
    end.

send(#sip{type = response, hdrs = Hdrs} = Resp) ->
    [Via|_] = esip:get_hdrs(via, Hdrs),
    VirtualHost = case esip:get_hdr(to, Hdrs) of
                      {_, #uri{host = Host}, _} ->
                          Host;
                      _ ->
                          undefined
                  end,
    case connect(Via, VirtualHost) of
        {ok, SIPSocket} ->
            send(SIPSocket, Resp);
        Err ->
            Err
    end;
send(#sip{type = request, uri = URI, hdrs = Hdrs} = Req) ->
    NewURI = case esip:get_hdrs(route, Hdrs) of
                 [{_, RouteURI, _}|_] ->
                     RouteURI;
                 _ ->
                     URI
             end,
    VirtualHost = case esip:get_hdr(from, Hdrs) of
                      {_, #uri{host = Host}, _} ->
                          Host;
                      _ ->
                          undefined
                  end,
    case connect(NewURI, VirtualHost) of
        {ok, SIPSock} ->
            send(SIPSock, Req);
        Err ->
            Err
    end.

connect(URIorVia, VHost) ->
    case resolve(URIorVia) of
        {ok, AddrsPorts, Transport} ->
            case lookup_socket(AddrsPorts, Transport) of
                {ok, Sock} ->
                    {ok, Sock};
                _ ->
                    case Transport of
                        tcp ->
                            esip_tcp:connect(AddrsPorts);
                        tls ->
                            esip_tcp:connect(AddrsPorts,
                                             [{tls, true}, {vhost, VHost}]);
                        sctp ->
                            esip_sctp:connect(AddrsPorts);
                        tls_sctp ->
                            esip_sctp:connect(AddrsPorts,
                                              [{tls, true}, {vhost, VHost}]);
                        udp ->
                            case ets:lookup(esip_route, udp) of
                                [{_, _, _, Pid}|_] ->
                                    esip_udp:connect(AddrsPorts, Pid);
                                _ ->
                                    {error, eprotonosupport}
                            end
                    end
            end;
        Err ->
            Err
    end.

via_transport_to_atom(<<"TLS">>) -> tls;
via_transport_to_atom(<<"TCP">>) -> tcp;
via_transport_to_atom(<<"UDP">>) -> udp;
via_transport_to_atom(<<"SCTP">>) -> sctp;
via_transport_to_atom(<<"TLS-SCTP">>) -> tls_sctp;
via_transport_to_atom(_) -> unknown.

atom_to_via_transport(tls) -> <<"TLS">>;
atom_to_via_transport(tcp) -> <<"TCP">>;
atom_to_via_transport(udp) -> <<"UDP">>;
atom_to_via_transport(sctp) -> <<"SCTP">>;
atom_to_via_transport(tls_sctp) -> <<"TLS-SCTP">>;
atom_to_via_transport(_) -> <<>>.

register_socket(Addr, Transport, Sock) ->
    register_socket(Addr, Transport, Sock, unlimited).

register_socket(Addr, Transport, Sock, Timeout) ->
    ets:insert(esip_socket, {{Addr, Transport}, Sock}),
    if Timeout /= unlimited ->
            erlang:send_after(Timeout, ?MODULE, {delete, Addr, Transport, Sock}),
            ok;
       true ->
            ok
    end.

unregister_socket(Addr, Transport, Sock) ->
    ets:delete_object(esip_socket, {{Addr, Transport}, Sock}).

lookup_socket([Addr|Rest], Transport) ->
    case lookup_socket(Addr, Transport) of
        {ok, Sock} ->
            {ok, Sock};
        _ ->
            lookup_socket(Rest, Transport)
    end;
lookup_socket([], _) ->
    error;
lookup_socket(Addr, Transport) ->
    case ets:lookup(esip_socket, {Addr, Transport}) of
        [{_, Sock}|_] ->
            {ok, Sock};
        _ ->
            error
    end.

register_route(Transport, Port) ->
    register_route(Transport, Port, self()).

register_route(Transport, Port, Owner) ->
    Host = esip:get_config_value(hostname),
    ets:insert(esip_route, {Transport, Host, Port, Owner}).

unregister_route(Transport, Port) ->
    unregister_route(Transport, Port, self()).

unregister_route(Transport, Port, Owner) ->
    Host = esip:get_config_value(hostname),
    ets:delete_object(esip_route, {Transport, Host, Port, Owner}).

have_route(Transport, Host, Port) ->
    case ets:match_object(esip_route, {Transport, Host, Port, '_'}) of
        [_|_] ->
            true;
        _ ->
            false
    end.

get_route() ->
    case ets:first(esip_route) of
        '$end_of_table' ->
            error;
        Key ->
            case ets:lookup(esip_route, Key) of
                [{Transport, Host, Port, _Owner}|_] ->
                    {ok, Transport, Host, Port};
                _ ->
                    error
            end
    end.

get_route(Transport) ->
    case ets:match(esip_route, {Transport, '$1', '$2', '_'}) of
        [[Host, Port]|_] ->
            {ok, Transport, Host, Port};
        _ ->
            error
    end.

make_via_hdr() ->
    make_via_hdr(esip:make_branch()).

make_via_hdr(Branch) ->
    case get_route() of
        {ok, Transport, Host, Port} ->
            {via, [#via{transport = atom_to_via_transport(Transport),
                        host = Host,
                        port = Port,
                        params = [{<<"branch">>, Branch},
                                  {<<"rport">>, <<>>}]}]};
        error ->
            {via, []}
    end.

make_via_hdr(Branch, Transport) ->
    case get_route(Transport) of
        {ok, _, Host, Port} ->
            {via, [#via{transport = atom_to_via_transport(Transport),
                        host = Host,
                        port = Port,
                        params = [{<<"branch">>, Branch},
                                  {<<"rport">>, <<>>}]}]};
        error ->
            {via, []}
    end.

make_contact() ->
    Host = esip:get_config_value(hostname),
    [{<<>>, #uri{host = Host}, []}].

make_contact(Transport) ->
    case get_route(Transport) of
        {ok, _, Host, Port} ->
            Scheme = case Transport of
                         tls -> <<"sips">>;
                         tls_sctp -> <<"sips">>;
                         _ -> <<"sip">>
                     end,
            Params = case Transport of
                         udp -> [{<<"transport">>, <<"udp">>}];
                         sctp -> [{<<"transport">>, <<"stcp">>}];
                         tcp -> [{<<"transport">>, <<"tcp">>}];
                         _ -> []
                     end,
            [{<<>>, #uri{scheme = Scheme, host = Host,
                         port = Port, params = Params}, []}];
        error ->
            []
    end.

fix_topmost_via(Transport, Hdrs) ->
    case esip:split_hdrs([via], Hdrs) of
        {[], RestHdrs} ->
            [make_via_hdr(esip:make_branch(), Transport)|RestHdrs];
        {[{via, [Via|Vias]}|RestVias], RestHdrs} ->
            NewVia = fix_via(Via, Transport),
            [{via, [NewVia|Vias]}|RestVias] ++ RestHdrs
    end.

fix_via(#via{transport = ViaT, host = Host, port = Port} = Via, T) ->
    case via_transport_to_atom(ViaT) of
        T ->
            Via;
        T1 ->
            case have_route(T1, Host, Port) of
                true ->
                    case get_route(T) of
                        {ok, _, NewHost, NewPort} ->
                            Via#via{host = NewHost,
                                    port = NewPort,
                                    transport = atom_to_via_transport(T)};
                        _ ->
                            Via
                    end;
                _ ->
                    Via
            end
    end.

transports('$end_of_table') ->
    [];
transports(T) ->
    [T|transports(ets:next(esip_route, T))].

supported_transports() ->
    transports(ets:first(esip_route)).

supported_transports(Type) ->
    lists:filter(
      fun(tls) when Type == tls ->
              true;
         (tls_sctp) when Type == tls ->
              true;
         (_) when Type == tls ->
              false;
         (_) ->
              true
      end, supported_transports()).

supported_uri_schemes() ->
    case supported_transports(tls) of
        [] ->
            [<<"sip">>];
        _ ->
            [<<"sips">>, <<"sip">>]
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    ets:new(esip_socket, [public, named_table, bag]),
    ets:new(esip_route, [public, named_table, bag]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, bad_request, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({delete, Addr, Transport, Sock}, State) ->
    unregister_socket(Addr, Transport, Sock),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================
prepare_request(#sip_socket{peer = {Addr, Port}, type = SockType},
                #sip{hdrs = Hdrs, type = Type} = Request) ->
    case esip:split_hdrs([via], Hdrs) of
        {[{_, [#via{params = Params, host = Host} = Via|RestVias]}|Vias],
         RestHdrs} ->
            case is_valid_via(Via, SockType)
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
                    Params2 = case esip:get_param(<<"rport">>, Params1, false) of
                                  <<>> ->
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

prepare_response(_SIPSock, Response) ->
    Response.

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

is_valid_via(#via{transport = Transport,
                  params = Params, version = Ver}, SockType) ->
    case via_transport_to_atom(Transport) of
        SockType ->
            case esip:get_param(<<"branch">>, Params) of
                <<"z9hG4bK", _/binary>> ->
                    true;
                Branch when Branch /= <<>>, Ver /= {2,0} ->
                    true;
                _ ->
                    false
            end;
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

do_send(#sip_socket{type = Type, sock = Sock,
                    peer = Peer, addr = Addr}, Msg) ->
    case catch esip_codec:encode(Msg) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to encode:~n"
		       "** Packet: ~p~n** Reason: ~p",
		       [Msg, Err]);
        Data ->
            esip:callback(data_out, [Type, Addr, Peer, Data]),
            case Type of
                udp -> esip_udp:send(Sock, Peer, Data);
                tcp -> esip_tcp:send(Sock, Data);
                tls -> esip_tcp:send(Sock, Data);
                sctp -> esip_sctp:send(Sock, Data);
                tls_sctp -> esip_sctp:send(Sock, Data)
            end
    end.

host_to_ip(Host) when is_binary(Host) ->
    host_to_ip(binary_to_list(Host));
host_to_ip(Host) ->
    case Host of
        "[" ->
            {error, einval};
        "[" ++ Rest ->
            inet_parse:ipv6_address(string:substr(Rest, 1, length(Rest)-1));
        _ ->
            inet_parse:address(Host)
    end.

srv_prefix(tls) -> "_sips._tcp.";
srv_prefix(tls_sctp) -> "_sips._sctp.";
srv_prefix(tcp) -> "_sip._tcp.";
srv_prefix(sctp) -> "_sip._sctp.";
srv_prefix(udp) -> "_sip._udp.".

default_port(tls) -> 5061;
default_port(tls_sctp) -> 5061;
default_port(_) -> 5060.

resolve(#uri{scheme = Scheme} = URI) ->
    case lists:member(Scheme, supported_uri_schemes()) of
        true ->
            SupportedTransports = case Scheme of
                                      <<"sips">> ->
                                          supported_transports(tls);
                                      _ ->
                                          supported_transports()
                                  end,
            case SupportedTransports of
                [] ->
                    {error, unsupported_transport};
                _ ->
                    resolve(URI, SupportedTransports)
            end;
        false ->
            {error, unsupported_uri_scheme}
    end;
resolve(#via{transport = ViaTransport} = Via) ->
    Transport = case ViaTransport of
                    <<"TLS">> -> tls;
                    <<"TLS-SCTP">> -> tls_sctp;
                    <<"TCP">> -> tcp;
                    <<"UDP">> -> udp;
                    <<"SCTP">> -> sctp;
                    _ -> unknown
                end,
    case lists:member(Transport, supported_transports()) of
        true ->
            resolve(Via, Transport);
        false ->
            {error, unsupported_transport}
    end.

resolve(#uri{host = Host, port = Port, params = Params}, SupportedTransports) ->
    case esip:get_param(<<"transport">>, Params) of
        <<>> ->
            [FallbackTransport|_] = lists:reverse(SupportedTransports),
            case host_to_ip(Host) of
                {ok, Addr} ->
                    select_host_port(Addr, Port, FallbackTransport);
                _ when is_integer(Port) ->
                    select_host_port(Host, Port, FallbackTransport);
                _ ->
                    case naptr_srv_lookup(Host, SupportedTransports) of
                        {ok, _, _} = Res ->
                            Res;
                        _Err ->
                            select_host_port(Host, Port, FallbackTransport)
                    end
            end;
        TransportBinary ->
            Transport = (catch erlang:binary_to_existing_atom(
                                 TransportBinary, utf8)),
            case lists:member(Transport, SupportedTransports) of
                true ->
                    case host_to_ip(Host) of
                        {ok, Addr} ->
                            select_host_port(Addr, Port, Transport);
                        _ when is_integer(Port) ->
                            select_host_port(Host, Port, Transport);
                        _ ->
                            case srv_lookup(Host, [Transport]) of
                                {ok, _, _} = Res ->
                                    Res;
                                _Err ->
                                    select_host_port(Host, Port, Transport)
                            end
                    end;
                false ->
                    {error, unsupported_transport}
            end
    end;
resolve(#via{transport = ViaTransport, host = Host,
             port = Port, params = Params}, Transport) ->
    NewPort = if ViaTransport == <<"UDP">> ->
                      case esip:get_param(<<"rport">>, Params) of
                          <<>> ->
                              Port;
                          RPort ->
                              case esip_codec:to_integer(RPort, 1, 65535) of
                                  {ok, PortInt} -> PortInt;
                                  _ -> Port
                              end
                      end;
                 true ->
                      Port
              end,
    NewHost = case esip:get_param(<<"received">>, Params) of
                  <<>> -> Host;
                  Host1 -> Host1
              end,
    case host_to_ip(NewHost) of
        {ok, Addr} ->
            select_host_port(Addr, NewPort, Transport);
        _ when is_integer(NewPort) ->
            select_host_port(NewHost, NewPort, Transport);
        _ ->
            case srv_lookup(NewHost, [Transport]) of
                {ok, _, _} = Res ->
                    Res;
                _Err ->
                    select_host_port(NewHost, NewPort, Transport)
            end
    end.

select_host_port(Addr, Port, Transport) when is_tuple(Addr) ->
    NewPort = if is_integer(Port) ->
                      Port;
                 true ->
                      default_port(Transport)
              end,
    {ok, [{Addr, NewPort}], Transport};
select_host_port(Host, Port, Transport) when is_integer(Port) ->    
    case a_lookup(Host) of
        {error, _} = Err ->
            Err;
        {ok, Addrs} ->
            {ok, [{Addr, Port} || Addr <- Addrs], Transport}
    end;
select_host_port(Host, Port, Transport) ->
    NewPort = if is_integer(Port) ->
                      Port;
                 true ->
                      default_port(Transport)
              end,
    case a_lookup(Host) of
        {ok, Addrs} ->
            {ok, [{Addr, NewPort} || Addr <- Addrs], Transport};
        Err ->
            Err
    end.

naptr_srv_lookup(Host, Transports) when is_binary(Host) ->
    naptr_srv_lookup(binary_to_list(Host), Transports);
naptr_srv_lookup(Host, Transports) ->
    case naptr_lookup(Host) of
        {error, _Err} ->
            srv_lookup(Host, Transports);
        SRVHosts ->
            case lists:filter(
                   fun({_, T}) ->
                           lists:member(T, Transports)
                   end, SRVHosts) of
                [{SRVHost, Transport}|_] ->
                    case srv_lookup(SRVHost) of
                        {error, _} = Err ->
                            Err;
                        AddrsPorts ->
                            {ok, AddrsPorts, Transport}
                    end;
                _ ->
                    srv_lookup(Host, Transports)
            end
    end.

srv_lookup(Host, Transports) when is_binary(Host) ->
    srv_lookup(binary_to_list(Host), Transports);
srv_lookup(Host, Transports) ->
    lists:foldl(
      fun(_Transport, {ok, _, _} = Acc) ->
              Acc;
         (Transport, Err) ->
              SRVHost = srv_prefix(Transport) ++ Host,
              case srv_lookup(SRVHost) of
                  {error, _} = Err ->
                      Err;
                  AddrsPorts ->
                      {ok, AddrsPorts, Transport}
              end
      end, {error, nxdomain}, Transports).

naptr_lookup(Host) when is_binary(Host) ->
    naptr_lookup(binary_to_list(Host));
naptr_lookup(Host) ->
    case inet_res:getbyname(Host, naptr) of
        {ok, #hostent{h_addr_list = Addrs}} ->
            lists:flatmap(
              fun({_Order, _Pref, _Flags, Service, _Regexp, SRVHost}) ->
                      case Service of
                          "sips+d2t" -> [{SRVHost, tls}];
                          "sips+d2s" -> [{SRVHost, tls_sctp}];
                          "sip+d2t" -> [{SRVHost, tcp}];
                          "sip+d2u" -> [{SRVHost, udp}];
                          "sip+d2s" -> [{SRVHost, sctp}];
                          _ -> []
                      end
              end, lists:keysort(1, Addrs));
        Err ->
            Err
    end.

srv_lookup(Host) when is_binary(Host) ->
    srv_lookup(binary_to_list(Host));
srv_lookup(Host) ->
    case inet_res:getbyname(Host, srv) of
        {ok, #hostent{h_addr_list = Rs}} ->
            case lists:flatmap(
                   fun({_, _, Port, HostName}) ->
                           case a_lookup(HostName) of
                               {ok, Addrs} ->
                                   [{Addr, Port} || Addr <- Addrs];
                               _ ->
                                   []
                           end
                   end, lists:keysort(1, Rs)) of
                [] ->
                    {error, nxdomain};
                Res ->
                    Res
            end;
        Err ->
            Err
    end.

a_lookup(Host) when is_binary(Host) ->
    a_lookup(binary_to_list(Host));
a_lookup(Host) ->
    case inet_res:getbyname(Host, a) of
        {ok, #hostent{h_addr_list = Addrs}} ->
            {ok, Addrs};
        Err ->
            case inet_res:getbyname(Host, aaaa) of
                {ok, #hostent{h_addr_list = Addrs}} ->
                    {ok, Addrs};
                Err ->
                    Err
            end
    end.
