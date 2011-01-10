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

-export([request/2, response/2, cancel/2, get_local_tag/1,
	 dialog_id/2, make_tag/0, make_branch/0, make_callid/0,
	 decode/1, decode_uri/1, decode_uri_field/1, encode/1,
	 encode_uri/1, encode_uri_field/1, match/2, rm_hdr/2,
         add_hdr/3, set_hdr/3, get_hdr/2, get_hdr_b/2, get_hdrs/2,
         split_hdrs/2, get_param/2, has_param/2, set_param/3,
         get_branch/1, make_response/2, make_response/3,
         get_config_value/1, set_config_value/2, get_config/0,
         timer1/0, timer2/0, timer4/0, reason/1, filter_hdrs/2,
         open_dialog/4, close_dialog/1, make_cseq/0, error_status/1,
         dialog_request/3, make_hdrs/0, mod/0, callback/1, callback/2,
         callback/3, send/1, dialog_send/2, ack/1, make_contact/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([behaviour_info/1]).

-include("esip.hrl").
-include("esip_lib.hrl").

-record(state, {}).

%%====================================================================
%% API
%%====================================================================
behaviour_info(callbacks) ->
    [{transaction_user, 1},
     {request, 2},
     {response, 1},
     {message_in, 4},
     {message_out, 4},
     {data_in, 4},
     {data_out, 4}].

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Opts], []).

start(Module, Opts) ->
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

request(Request, TU) ->
    esip_transaction:request(Request, TU).

response(TrID, Response) ->
    esip_transaction:response(TrID, Response).

dialog_request(DialogID, Req, TU) ->
    NewReq = esip_dialog:prepare_request(DialogID, Req),
    esip_transaction:request(NewReq, TU).

cancel(TrID, TU) ->
    esip_transaction:cancel(TrID, TU).

send(Msg) ->
    esip_transport:send(Msg).

dialog_send(DialogID = #dialog_id{}, #sip{type = request} = Req) ->
    NewReq = esip_dialog:prepare_request(DialogID, Req),
    esip_transport:send(NewReq).

ack(DialogID = #dialog_id{}) ->
    dialog_send(DialogID, #sip{type = request,
                               method = <<"ACK">>,
                               hdrs = esip:make_hdrs()}).

make_tag() ->
    gen_server:call(?MODULE, make_tag).

make_branch() ->
    gen_server:call(?MODULE, make_branch).

make_callid() ->
    gen_server:call(?MODULE, make_callid).

make_cseq() ->
    gen_server:call(?MODULE, make_cseq).

make_hdrs() ->
    [{cseq, make_cseq()},
     {'max-forwards', get_config_value(max_forwards)},
     {'call-id', make_callid()}].

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
    case lists:keysearch(Hdr, 1, Hdrs) of
        {value, {_, Val}} ->
            Val;
        false ->
            undefined
    end.

get_hdr_b(Hdr, Hdrs) ->
    case lists:keysearch(Hdr, 1, Hdrs) of
        {value, {_, Val}} ->
            Val;
        false ->
            <<>>
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

split_hdrs(HdrList, Hdrs) ->
    lists:partition(
      fun({Hdr, _}) ->
              lists:member(Hdr, HdrList)
      end, Hdrs).

get_param(Param, Params) ->
    case lists:keysearch(Param, 1, Params) of
        {value, {_, Val}} ->
            Val;
        false ->
            <<>>
    end.

has_param(Param, Params) ->
    case lists:keysearch(Param, 1, Params) of
        {value, _} ->
            true;
        false ->
            false
    end.

set_param(Param, Val, Params) ->
    set_hdr(Param, Val, Params).

get_branch(Hdrs) ->
    [Via|_] = get_hdr(via, Hdrs),
    get_param(<<"branch">>, Via#via.params).

make_contact(Transport) ->
    esip_transport:make_contact(Transport).

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
                       filter_hdrs([via, from, 'call-id', cseq,
                                    'max-forwards', to, timestamp], ReqHdrs);
                  true ->
                       filter_hdrs([via, from, 'call-id', cseq,
                                    'max-forwards', to], ReqHdrs)
               end,
    NewNeedHdrs =
        if Status > 100 ->
                {ToName, ToURI, ToParams} = get_hdr(to, NeedHdrs),
                case has_param(<<"tag">>, ToParams) of
                    false ->
                        NewTo = {ToName, ToURI, [{<<"tag">>, Tag}|ToParams]},
                        set_hdr(to, NewTo, NeedHdrs);
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
    Resp#sip{method = NewMethod, hdrs = NewNeedHdrs ++ RespHdrs}.

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
error_status(nxdomain) ->
    {503, reason(503)};
error_status(internal_server_error) ->
    {500, reason(500)};
error_status(_) ->
    {500, reason(500)}.

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

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Opts]) ->
    {A, B, C} = now(),
    random:seed(A, B, C),
    self() ! {init, Opts},
    ets:new(esip_config, [named_table, public]),
    set_config(Opts),
    {ok, #state{}}.

handle_call(make_tag, _From, State) ->
    Rnd = erlang:integer_to_list(random:uniform(1 bsl 32)),
    {reply, iolist_to_binary([Rnd]), State};
handle_call(make_branch, _From, State) ->
    Rnd = erlang:integer_to_list(random:uniform(1 bsl 32)),
    {reply, iolist_to_binary(["z9hG4bK-", Rnd]), State};
handle_call(make_callid, _From, State) ->
    RndStr = erlang:integer_to_list(random:uniform(1 bsl 32)),
    Reply = iolist_to_binary([RndStr, "@", get_config_value(hostname)]),
    {reply, Reply, State};
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
              esip_listener:add_listener(Port, Transport, LOpts);
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
    {ok, HostName} = inet:gethostname(),
    [{hostname, HostName},
     {max_forwards, 70},
     {timer1, 500},
     {timer2, 4000},
     {timer4, 5000},
     {max_msg_size, 128*1024}].

set_config(Opts) ->
    lists:foreach(
      fun({hostname, HostName}) ->
              ets:insert(esip_config, {hostname, list_to_binary(HostName)});
         ({Key, Value}) ->
              ets:insert(esip_config, {Key, Value});
         (_) ->
              ok
      end, default_config() ++ Opts).
