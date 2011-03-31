%%%-------------------------------------------------------------------
%%% File    : sip.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Main SIP instance
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip).

-behaviour(gen_server).

%% API
-export([start_link/1, start/2, stop/0]).

-export([ack/1,
         add_hdr/3,
         callback/1,
         callback/2,
         callback/3,
         cancel/1,
         cancel/2,
         check_auth/4,
         close_dialog/1,
         decode/1,
         decode_uri/1,
         decode_uri_field/1,
         dialog_id/2,
         dialog_request/2,
         dialog_request/3,
         dialog_request/4,
         dialog_send/2,
         encode/1,
         encode_uri/1,
         encode_uri_field/1,
         error_status/1,
         escape/1,
         filter_hdrs/2,
         get_branch/1,
         get_config/0,
         get_config_value/1,
         get_hdr/2,
         get_hdr/3,
         get_hdrs/2,
         get_local_tag/1,
         get_node_by_tag/1,
         get_param/2,
         get_param/3,
         get_so_path/0,
         has_param/2,
         hex_encode/1,
         is_my_via/1,
         make_auth/6,
         make_branch/0,
         make_branch/1,
         make_callid/0,
         make_contact/0,
         make_contact/1,
         make_contact/2,
         make_cseq/0,
         make_hdrs/0,
         make_hexstr/1,
         make_response/2,
         make_response/3,
         make_tag/0,
         match/2,
         mod/0,
         open_dialog/4,
         quote/1,
         reason/1,
         reply/2,
         request/1,
         request/2,
         request/3,
         rm_hdr/2,
         send/1,
         send/2,
         set_config_value/2,
         set_hdr/3,
         set_param/3,
         split_hdrs/2,
         stop_transaction/1,
         timer1/0,
         timer2/0,
         timer4/0,
         to_lower/1,
         unescape/1,
         unquote/1,
         warning/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([behaviour_info/1]).

-include("esip.hrl").
-include("esip_lib.hrl").

-record(state, {node_id}).

%%====================================================================
%% API
%%====================================================================
behaviour_info(callbacks) ->
    [{request, 3},
     {request, 2},
     {response, 2},
     {message_in, 2},
     {message_out, 2},
     {data_in, 2},
     {data_out, 2}].

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Opts], []).

start(Module, Opts) ->
    crypto:start(),
    ChildSpec = {?MODULE,
		 {?MODULE, start_link, [[{module, Module}|Opts]]},
		 transient, 2000, worker,
		 [?MODULE]},
    case application:start(esip) of
	ok ->
	    supervisor:start_child(esip_sup, ChildSpec);
	{error,{already_started, _}} ->
	    supervisor:start_child(esip_sup, ChildSpec);
	Err ->
	    Err
    end.

stop() ->
    application:stop(esip).

get_so_path() ->
    case os:getenv("ESIP_SO_PATH") of
        false ->
            case code:priv_dir(esip) of
                {error, _} ->
                    ".";
                Path ->
                    filename:join([Path, "lib"])
            end;
        Path ->
            Path
    end.

request(Request) ->
    request(Request, undefined).

request(Request, TU) ->
    request(Request, TU, []).

request(Request, TU, Opts) ->
    esip_transaction:request(Request, TU, Opts).

reply(RequestOrTrID, Response) ->
    esip_transaction:reply(RequestOrTrID, Response).

dialog_request(DialogID, Req) ->
    dialog_request(DialogID, Req, undefined).

dialog_request(DialogID, Req, TU) ->
    dialog_request(DialogID, Req, TU, []).

dialog_request(DialogID, Req, TU, Opts) ->
    NewReq = esip_dialog:prepare_request(DialogID, Req),
    esip_transaction:request(NewReq, TU, Opts).

cancel(RequestOrTrID) ->
    cancel(RequestOrTrID, undefined).

cancel(RequestOrTrID, TU) ->
    esip_transaction:cancel(RequestOrTrID, TU).

send(ReqOrResp) ->
    send(ReqOrResp, []).

send(#sip{type = request, hdrs = Hdrs} = Req, Opts) ->
    {_, #uri{host = VHost}, _} = get_hdr('from', Hdrs),
    Branch = esip:make_branch(Hdrs),
    NewHdrs = [esip_transport:make_via_hdr(VHost, Branch)|Hdrs],
    esip_transport:send(Req#sip{hdrs = NewHdrs}, Opts);
send(Resp, Opts) ->
    esip_transport:send(Resp, Opts).

dialog_send(DialogID, Req) ->
    dialog_send(DialogID, Req, []).

dialog_send(DialogID = #dialog_id{}, #sip{type = request} = Req, Opts) ->
    NewReq = esip_dialog:prepare_request(DialogID, Req),
    esip_transport:send(NewReq, Opts).

ack(DialogID) ->
    ack(DialogID, []).

ack(DialogID = #dialog_id{}, Opts) ->
    dialog_send(DialogID, #sip{type = request,
                               method = <<"ACK">>,
                               hdrs = make_hdrs()}, Opts).

stop_transaction(TrID) ->
    esip_transaction:stop(TrID).

make_tag() ->
    {NodeID, N} = gen_server:call(?MODULE, make_tag),
    iolist_to_binary([NodeID, $-, int_to_list(N)]).

make_branch() ->
    N = gen_server:call(?MODULE, make_branch),
    iolist_to_binary(["z9hG4bK-", int_to_list(N)]).

make_branch(Hdrs) ->
    case get_hdrs('via', Hdrs) of
        [] ->
            make_branch();
        [Via|_] ->
            TopBranch = to_lower(get_param(<<"branch">>, Via#via.params)),
            Cookie = atom_to_list(erlang:get_cookie()),
            ID = hex_encode(erlang:md5([TopBranch, Cookie])),
            iolist_to_binary(["z9hG4bK-", ID])
    end.

make_callid() ->
    N = gen_server:call(?MODULE, make_callid),
    iolist_to_binary([int_to_list(N)]).

make_cseq() ->
    gen_server:call(?MODULE, make_cseq).

make_hdrs() ->
    Hdrs = [{'cseq', make_cseq()},
            {'max-forwards', get_config_value(max_forwards)},
            {'call-id', make_callid()}],
    case get_config_value(software) of
        undefined ->
            Hdrs;
        Software ->
            [{'user-agent', Software}|Hdrs]
    end.

get_local_tag(TrID) ->
    esip_lib:get_local_tag(TrID).

dialog_id(Type, SIPMsg) ->
    esip_dialog:id(Type, SIPMsg).

open_dialog(Request, ResponseOrTag, TypeOrState, TU) ->
    esip_dialog:open(Request, ResponseOrTag, TypeOrState, TU).

close_dialog(DialogID) ->
    esip_dialog:close(DialogID).

decode(Data) ->
    esip_codec:decode(Data).

decode_uri(Data) ->
    esip_codec:decode_uri(Data).

decode_uri_field(Data) ->
    esip_codec:decode_uri_field(Data).

encode(R) ->
    esip_codec:encode(R).

encode_uri(URI) ->
    esip_codec:encode_uri(URI).

encode_uri_field(URI) ->
    esip_codec:encode_uri_field(URI).

match(Arg1, Arg2) ->
    esip_codec:match(Arg1, Arg2).

rm_hdr(Key, Hdrs) ->
    lists:filter(
      fun({K, _}) ->
              K /= Key
      end, Hdrs).

add_hdr(Key, Val, Hdrs) ->
    case lists:foldl(
           fun({K, V}, {false, Acc}) when K == Key ->
                   {true, [{K, V}, {Key, Val}|Acc]};
              (KV, {S, Acc}) ->
                   {S, [KV|Acc]}
           end, {false, []}, Hdrs) of
        {true, Res} ->
            lists:reverse(Res);
        {false, Res} ->
            lists:reverse([{Key, Val}|Res])
    end.

set_hdr(Key, Val, Hdrs) ->
    Res = lists:foldl(
            fun({K, _}, Acc) when K == Key ->
                    Acc;
               (KV, Acc) ->
                    [KV|Acc]
            end, [], Hdrs),
    lists:reverse([{Key, Val}|Res]).

get_hdr(Hdr, Hdrs) ->
    get_hdr(Hdr, Hdrs, undefined).

get_hdr(Hdr, Hdrs, Default) ->
    case lists:keysearch(Hdr, 1, Hdrs) of
        {value, {_, Val}} ->
            Val;
        false ->
            Default
    end.

get_hdrs(Hdr, Hdrs) ->
    lists:flatmap(
      fun({K, V}) when K == Hdr ->
              if is_list(V) ->
                      V;
                 true ->
                      [V]
              end;
         (_) ->
              []
      end, Hdrs).

filter_hdrs(HdrList, Hdrs) ->
    lists:filter(
      fun({Hdr, _}) ->
              lists:member(Hdr, HdrList)
      end, Hdrs).

split_hdrs(HdrList, Hdrs) when is_list(HdrList) ->
    lists:partition(
      fun({Hdr, _}) ->
              lists:member(Hdr, HdrList)
      end, Hdrs);
split_hdrs(Hdr, Hdrs) ->
    lists:foldr(
      fun({K, V}, {H, T}) when K == Hdr ->
              if is_list(V) ->
                      {V++H, T};
                 true ->
                      {[V|H], T}
              end;
         ({K, V}, {H, T}) ->
              {H, [{K, V}|T]}
      end, {[], []}, Hdrs).

get_param(Param, Params) ->
    get_param(Param, Params, <<>>).

get_param(Param, Params, Default) ->
    case lists:keysearch(Param, 1, Params) of
        {value, {_, Val}} ->
            Val;
        false ->
            get_param_lower(Param, Params, Default)
    end.

get_param_lower(Param, [{P, Val}|Tail], Default) ->
    case esip_codec:to_lower(P) of
        Param ->
            Val;
        _ ->
            get_param_lower(Param, Tail, Default)
    end;
get_param_lower(_, [], Default) ->
    Default.

has_param(Param, Params) ->
    case get_param(Param, Params, undefined) of
        undefined ->
            false;
        _ ->
            true
    end.

set_param(Param, Val, Params) ->
    Res = lists:foldl(
            fun({P, V}, Acc) ->
                    case esip_codec:to_lower(P) of
                        Param ->
                            Acc;
                        _ ->
                            [{P, V}|Acc]
                    end
            end, [], Params),
    lists:reverse([{Param, Val}|Res]).

get_branch(Hdrs) ->
    [Via|_] = get_hdr('via', Hdrs),
    get_param(<<"branch">>, Via#via.params).

is_my_via(#via{transport = Transport, host = Host, port = Port}) ->
    esip_transport:have_route(
      esip_transport:via_transport_to_atom(Transport), Host, Port).

escape(Bin) ->
    esip_codec:escape(Bin).

unescape(Bin) ->
    esip_codec:unescape(Bin).

make_contact() ->
    esip_transport:make_contact().

make_contact(VHost) ->
    esip_transport:make_contact(VHost).

make_contact(VHost, Transport) ->
    esip_transport:make_contact(VHost, Transport).

make_response(Req, Resp) ->
    make_response(Req, Resp, <<>>).

make_response(#sip{hdrs = ReqHdrs,
                   method = Method,
                   type = request},
              #sip{status = Status,
                   hdrs = RespHdrs,
                   method = RespMethod,
                   type = response} = Resp, Tag) ->
    NeedHdrs = if Status == 100 ->
                       filter_hdrs(['via', 'from', 'call-id', 'cseq',
                                    'max-forwards', 'to', 'timestamp'], ReqHdrs);
                  Status > 100, Status < 300 ->
                       filter_hdrs(['via', 'record-route', 'from', 'call-id',
                                    'cseq', 'max-forwards', 'to'], ReqHdrs);
                  true ->
                       filter_hdrs(['via', 'from', 'call-id', 'cseq',
                                    'max-forwards', 'to'], ReqHdrs)
               end,
    NewNeedHdrs =
        if Status > 100 ->
                {ToName, ToURI, ToParams} = get_hdr('to', NeedHdrs),
                case has_param(<<"tag">>, ToParams) of
                    false ->
                        NewTo = {ToName, ToURI, [{<<"tag">>, Tag}|ToParams]},
                        set_hdr('to', NewTo, NeedHdrs);
                    true ->
                        NeedHdrs
                end;
           true ->
                NeedHdrs
        end,
    NewMethod = if RespMethod /= undefined ->
                        RespMethod;
                   true ->
                        Method
                end,
    ResultHdrs = case get_config_value(software) of
                     undefined ->
                         NewNeedHdrs ++ RespHdrs;
                     Software ->
                         NewNeedHdrs ++ [{'server', Software}|RespHdrs]
                 end,
    Resp#sip{method = NewMethod, hdrs = ResultHdrs}.

make_auth({Type, Params}, Method, Body, OrigURI, Username, Password) ->
    Nonce = esip:get_param(<<"nonce">>, Params),
    QOPs = esip:get_param(<<"qop">>, Params),
    Algo = case esip:get_param(<<"algorithm">>, Params) of
               <<>> ->
                   <<"MD5">>;
               Algo1 ->
                   Algo1
           end,
    Realm = esip:get_param(<<"realm">>, Params),
    OpaqueParam = case esip:get_param(<<"opaque">>, Params) of
                      <<>> ->
                          [];
                      Opaque ->
                          [{<<"opaque">>, Opaque}]
                  end,
    CNonce = make_hexstr(20),
    NC = <<"00000001">>, %% TODO
    URI = if is_binary(OrigURI) ->
                  OrigURI;
             is_record(OrigURI, uri) ->
                  iolist_to_binary(esip_codec:encode_uri(OrigURI))
          end,
    QOPList = esip_codec:split(unquote(QOPs), $,),
    QOP = case lists:member(<<"auth">>, QOPList) of
              true ->
                  <<"auth">>;
              false ->
                  case lists:member(<<"auth-int">>, QOPList) of
                      true ->
                          <<"auth-int">>;
                      false ->
                          <<>>
                  end
          end,
    Response = compute_digest(Nonce, CNonce, NC, QOP, Algo,
                              Realm, URI, Method, Body,
                              Username, Password),
    {Type, [{<<"username">>, quote(Username)},
            {<<"realm">>, Realm},
            {<<"nonce">>, Nonce},
            {<<"uri">>, quote(URI)},
            {<<"response">>, quote(Response)},
            {<<"algorithm">>, Algo} |
            if QOP /= <<>> ->
                    [{<<"cnonce">>, quote(CNonce)},
                     {<<"nc">>, NC},
                     {<<"qop">>, QOP}];
               true ->
                    []
            end] ++ OpaqueParam}.

check_auth({Type, Params}, Method, Body, Password) ->
    case to_lower(Type) of
        <<"digest">> ->
            NewMethod = case Method of
                            <<"ACK">> -> <<"INVITE">>;
                            _ -> Method
                        end,
            Nonce = esip:get_param(<<"nonce">>, Params),
            NC = esip:get_param(<<"nc">>, Params),
            CNonce = esip:get_param(<<"cnonce">>, Params),
            QOP = esip:get_param(<<"qop">>, Params),
            Algo = esip:get_param(<<"algorithm">>, Params),
            Username = esip:get_param(<<"username">>, Params),
            Realm = esip:get_param(<<"realm">>, Params),
            URI = esip:get_param(<<"uri">>, Params),
            Response = unquote(esip:get_param(<<"response">>, Params)),
            Response == compute_digest(Nonce, CNonce, NC, QOP,
                                       Algo, Realm, URI, NewMethod, Body,
                                       Username, Password);
        _ ->
            false
    end.

make_hexstr(N) ->
    hex_encode(crypto:rand_bytes(N)).

hex_encode(Data) ->
    << <<(esip_codec:to_hex(X))/binary>> || <<X>> <= Data >>.

to_lower(Bin) ->
    esip_codec:to_lower(Bin).

get_config() ->
    ets:tab2list(esip_config).

get_config_value(Key) ->
    case ets:lookup(esip_config, Key) of
        [{_, Val}] ->
            Val;
        _ ->
            undefined
    end.

mod() ->
    get_config_value(module).

set_config_value(Key, Val) ->
    ets:insert(esip_config, {Key, Val}).

callback({M, F, A}) ->
    callback(M, F, A).

callback(F, Args) when is_function(F) ->
    case catch apply(F, Args) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to process callback:~n"
                       "** Function: ~p~n"
                       "** Args: ~p~n"
                       "** Reason: ~p",
                       [F, Args, Err]),
            {error, internal_server_error};
        Result ->
            Result
    end;
callback(F, Args) ->
    callback(get_config_value(module), F, Args).

callback(Mod, Fun, Args) ->
    case catch apply(Mod, Fun, Args) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to process callback:~n"
                       "** Function: ~p:~p/~p~n"
                       "** Args: ~p~n"
                       "** Reason: ~p",
                       [Mod, Fun, length(Args), Args, Err]),
            {error, internal_server_error};
        Result ->
            Result
    end.

%% Basic Timers
timer1() -> get_config_value(timer1).
timer2() -> get_config_value(timer2).
timer4() -> get_config_value(timer4).

error_status({error, Err}) ->
    error_status(Err);
error_status(timeout) ->
    {408, reason(408)};
error_status(no_contact_header) ->
    {400, <<"Missed Contact header">>};
error_status(too_many_transactions) ->
    {500, <<"Too Many Transactions">>};
error_status(Err) when is_atom(Err) ->
    case inet:format_error(Err) of
        "unknown POSIX error" ->
            {500, reason(500)};
        [H|T] when H >= $a, H =< $z ->
            {503, list_to_binary([H - $ |T])};
        Txt ->
            {503, Txt}
    end;
error_status(_) ->
    {500, reason(500)}.

get_node_by_tag(Tag) ->
    case esip_codec:split(Tag, $-, 1) of
        [NodeID, _] ->
            get_node_by_id(NodeID);
        _ ->
            node()
    end.

get_node_by_id(NodeID) when is_binary(NodeID) ->
    case catch erlang:binary_to_existing_atom(NodeID, utf8) of
        {'EXIT', _} ->
            node();
        Res ->
            get_node_by_id(Res)
    end;
get_node_by_id(NodeID) ->
    case global:whereis_name(NodeID) of
        Pid when is_pid(Pid) ->
            node(Pid);
        _ ->
            node()
    end.

%% From http://www.iana.org/assignments/sip-parameters
reason(100) -> <<"Trying">>;
reason(180) -> <<"Ringing">>;
reason(181) -> <<"Call Is Being Forwarded">>;
reason(182) -> <<"Queued">>;
reason(183) -> <<"Session Progress">>;
reason(200) -> <<"OK">>;
reason(202) -> <<"Accepted">>;
reason(204) -> <<"No Notification">>;
reason(300) -> <<"Multiple Choices">>;
reason(301) -> <<"Moved Permanently">>;
reason(302) -> <<"Moved Temporarily">>;
reason(305) -> <<"Use Proxy">>;
reason(380) -> <<"Alternative Service">>;
reason(400) -> <<"Bad Request">>;
reason(401) -> <<"Unauthorized">>;
reason(402) -> <<"Payment Required">>;
reason(403) -> <<"Forbidden">>;
reason(404) -> <<"Not Found">>;
reason(405) -> <<"Method Not Allowed">>;
reason(406) -> <<"Not Acceptable">>;
reason(407) -> <<"Proxy Authentication Required">>;
reason(408) -> <<"Request Timeout">>;
reason(410) -> <<"Gone">>;
reason(412) -> <<"Conditional Request Failed">>;
reason(413) -> <<"Request Entity Too Large">>;
reason(414) -> <<"Request-URI Too Long">>;
reason(415) -> <<"Unsupported Media Type">>;
reason(416) -> <<"Unsupported URI Scheme">>;
reason(417) -> <<"Unknown Resource-Priority">>;
reason(420) -> <<"Bad Extension">>;
reason(421) -> <<"Extension Required">>;
reason(422) -> <<"Session Interval Too Small">>;
reason(423) -> <<"Interval Too Brief">>;
reason(428) -> <<"Use Identity Header">>;
reason(429) -> <<"Provide Referrer Identity">>;
reason(430) -> <<"Flow Failed">>;
reason(433) -> <<"Anonymity Disallowed">>;
reason(436) -> <<"Bad Identity-Info">>;
reason(437) -> <<"Unsupported Certificate">>;
reason(438) -> <<"Invalid Identity Header">>;
reason(439) -> <<"First Hop Lacks Outbound Support">>;
reason(440) -> <<"Max-Breadth Exceeded">>;
reason(469) -> <<"Bad Info Package">>;
reason(470) -> <<"Consent Needed">>;
reason(480) -> <<"Temporarily Unavailable">>;
reason(481) -> <<"Call/Transaction Does Not Exist">>;
reason(482) -> <<"Loop Detected">>;
reason(483) -> <<"Too Many Hops">>;
reason(484) -> <<"Address Incomplete">>;
reason(485) -> <<"Ambiguous">>;
reason(486) -> <<"Busy Here">>;
reason(487) -> <<"Request Terminated">>;
reason(488) -> <<"Not Acceptable Here">>;
reason(489) -> <<"Bad Event">>;
reason(491) -> <<"Request Pending">>;
reason(493) -> <<"Undecipherable">>;
reason(494) -> <<"Security Agreement Required">>;
reason(500) -> <<"Server Internal Error">>;
reason(501) -> <<"Not Implemented">>;
reason(502) -> <<"Bad Gateway">>;
reason(503) -> <<"Service Unavailable">>;
reason(504) -> <<"Server Time-out">>;
reason(505) -> <<"Version Not Supported">>;
reason(513) -> <<"Message Too Large">>;
reason(580) -> <<"Precondition Failure">>;
reason(600) -> <<"Busy Everywhere">>;
reason(603) -> <<"Decline">>;
reason(604) -> <<"Does Not Exist Anywhere">>;
reason(606) -> <<"Not Acceptable">>;
reason(Status) when Status > 100, Status < 200 ->
    <<"Session Progress">>;
reason(Status) when Status > 200, Status < 300 ->
    <<"Accepted">>;
reason(Status) when Status > 300, Status < 400 ->
    <<"Multiple Choices">>;
reason(Status) when Status > 400, Status < 500 ->
    <<"Bad Request">>;
reason(Status) when Status > 500, Status < 600 ->
    <<"Server Internal Error">>;
reason(Status) when Status > 600, Status < 700 ->
    <<"Busy Everywhere">>.

warning(300) -> <<"\"Incompatible network protocol\"">>;
warning(301) -> <<"\"Incompatible network address formats\"">>;
warning(302) -> <<"\"Incompatible transport protocol\"">>;
warning(303) -> <<"\"Incompatible bandwidth units\"">>;
warning(304) -> <<"\"Media type not available\"">>;
warning(305) -> <<"\"Incompatible media format\"">>;
warning(306) -> <<"\"Attribute not understood\"">>;
warning(307) -> <<"\"Session description parameter not understood\"">>;
warning(330) -> <<"\"Multicast not available\"">>;
warning(331) -> <<"\"Unicast not available\"">>;
warning(370) -> <<"\"Insufficient bandwidth\"">>;
warning(380) -> <<"\"SIPS Not Allowed\"">>;
warning(381) -> <<"\"SIPS Required\"">>;
warning(399) -> <<"\"Miscellaneous warning\"">>;
warning(Code) when Code > 300, Code < 400 -> <<"\"\"">>.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Opts]) ->
    {A, B, C} = now(),
    random:seed(A, B, C),
    self() ! {init, Opts},
    ets:new(esip_config, [named_table, public]),
    set_config(Opts),
    NodeID = list_to_binary(integer_to_list(random:uniform(1 bsl 32))),
    register_node(NodeID),
    {ok, #state{node_id = NodeID}}.

handle_call(make_tag, _From, State) ->
    {reply, {State#state.node_id, random:uniform(1 bsl 32)}, State};
handle_call(make_branch, _From, State) ->
    {reply, random:uniform(1 bsl 48), State};
handle_call(make_callid, _From, State) ->
    {reply, random:uniform(1 bsl 48), State};
handle_call(make_cseq, _From, State) ->
    {reply, random:uniform(1 bsl 10), State};
handle_call(stop, _From, State) ->
    {stop, normal, State};
handle_call(_Request, _From, State) ->
    {reply, bad_request, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({init, Opts}, State) ->
    lists:foreach(
      fun({listen, Port, Transport, LOpts}) ->
              case esip_listener:add_listener(Port, Transport, LOpts) of
                  {error, _} ->
                      ok;
                  _ ->
                      ets:insert(esip_config,
                                 {{listen, Port, Transport}, LOpts})
              end;
         ({route, VirtualHost, Transport, ROpts} = Route) ->
              case process_route(Route) of
                  ok ->
                      ets:insert(esip_config,
                                 {{route, VirtualHost, Transport}, ROpts});
                  _ ->
                      ?ERROR_MSG("Invalid 'route' option: ~p", [Route])
              end;
         (_) ->
              ok
      end, Opts),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
default_config() ->
    Software = case catch application:get_key(esip, vsn) of
                   {ok, [_|_] = Ver} ->
                       list_to_binary(["esip/", Ver]);
                   _ ->
                       <<"esip">>
               end,
    [{max_forwards, 70},
     {timer1, 500},
     {timer2, 4000},
     {timer4, 5000},
     {software, Software},
     {max_msg_size, 128*1024}].

set_config(Opts) ->
    lists:foreach(
      fun({Key, Value}) ->
              ets:insert(esip_config, {Key, Value});
         (_) ->
              ok
      end, default_config() ++ Opts).

int_to_list(N) ->
    erlang:integer_to_list(N).

register_node(NodeID) ->
    global:register_name(erlang:binary_to_atom(NodeID, utf8), self()).

process_route({route, VirtualHost, Transport, ROpts}) ->
    VHost = if is_list(VirtualHost) ->
                    list_to_binary(VirtualHost);
               is_binary(VirtualHost) ->
                    VirtualHost;
               true ->
                    undefined
            end,
    Host = case lists:keysearch(host, 1, ROpts) of
               {value, {_, HostName}} ->
                   iolist_to_binary(HostName);
               _ ->
                   VHost
           end,
    Port = case lists:keysearch(port, 1, ROpts) of
               {value, {_, RPort}} ->
                   RPort;
               _ ->
                   undefined
           end,
    if Host /= undefined ->
            esip_transport:register_route(VHost, Transport, Host, Port),
            ok;
       true ->
            error
    end.

unquote(<<$", Rest/binary>>) ->
    case size(Rest) - 1 of
        Size when Size > 0 ->
            <<Result:Size/binary, _>> = Rest,
            Result;
        _ ->
            <<>>
    end;
unquote(Val) ->
    Val.

quote(Val) ->
    <<$", Val/binary, $">>.

md5_digest(Data) ->
    hex_encode(erlang:md5(Data)).

compute_digest(Nonce, CNonce, NC, QOP, Algo, Realm,
               URI, Method, Body, Username, Password) ->
    AlgoL = to_lower(Algo),
    QOPL = to_lower(QOP),
    A1 = if AlgoL == <<"md5">>; AlgoL == <<>> ->
                 [unquote(Username), $:, unquote(Realm), $:, Password];
            true ->
                 [md5_digest([unquote(Username), $:,
                              unquote(Realm), $:, Password]),
                  $:, unquote(Nonce), $:, unquote(CNonce)]
         end,
    A2 = if QOPL == <<"auth">>; QOPL == <<>> ->
                 [Method, $:, unquote(URI)];
            true ->
                 [Method, $:, unquote(URI), $:, md5_digest(Body)]
         end,
    if QOPL == <<"auth">>; QOPL == <<"auth-int">> ->
            md5_digest(
              [md5_digest(A1),
               $:, unquote(Nonce),
               $:, NC,
               $:, unquote(CNonce),
               $:, unquote(QOP),
               $:, md5_digest(A2)]);
       true ->
            md5_digest(
              [md5_digest(A1),
               $:, unquote(Nonce),
               $:, md5_digest(A2)])
    end.
