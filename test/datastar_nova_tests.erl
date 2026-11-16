-module(datastar_nova_tests).
-eqwalizer(ignore).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nova/include/nova_pubsub.hrl").

%% -- handle/3 -----------------------------------------------------------------
%%
%% Build a fake Nova/Cowboy Req map and assert that handle/3 populates it
%% correctly. The real cowboy_req:set_resp_* functions operate on this
%% same map shape; by using the map directly we test the contract without
%% needing Cowboy running.

-define(EMPTY_REQ, #{resp_headers => #{}, resp_body => <<>>}).

handle_default_status_test() ->
    Events = datastar:patch_elements(~"<p>hi</p>"),
    {ok, Req} = datastar_nova:handle({datastar, Events}, fun erlang:date/0, ?EMPTY_REQ),
    ?assertEqual(200, maps:get(resp_status_code, Req)),
    Body = maps:get(resp_body, Req),
    ?assertMatch({_, _}, binary:match(Body, ~"event: datastar-patch-elements")),
    ?assertMatch({_, _}, binary:match(Body, ~"<p>hi</p>")).

handle_sets_sse_headers_test() ->
    Events = datastar:patch_signals(#{x => 1}),
    {ok, Req} = datastar_nova:handle({datastar, Events}, fun erlang:date/0, ?EMPTY_REQ),
    Headers = maps:get(resp_headers, Req),
    ?assertEqual(~"text/event-stream", maps:get(~"content-type", Headers)),
    ?assertEqual(~"no-cache", maps:get(~"cache-control", Headers)),
    ?assertEqual(~"keep-alive", maps:get(~"connection", Headers)).

handle_custom_status_test() ->
    Events = datastar:patch_elements(~"<p/>"),
    {ok, Req} = datastar_nova:handle({datastar, 202, Events}, fun erlang:date/0, ?EMPTY_REQ),
    ?assertEqual(202, maps:get(resp_status_code, Req)).

handle_extra_headers_merge_over_defaults_test() ->
    Events = datastar:patch_elements(~"<p/>"),
    Extra = #{~"x-trace-id" => ~"abc"},
    {ok, Req} = datastar_nova:handle(
        {datastar, 200, Extra, Events},
        undefined,
        ?EMPTY_REQ
    ),
    Headers = maps:get(resp_headers, Req),
    ?assertEqual(~"abc", maps:get(~"x-trace-id", Headers)),
    ?assertEqual(~"text/event-stream", maps:get(~"content-type", Headers)).

handle_extra_headers_can_override_defaults_test() ->
    Events = datastar:patch_elements(~"<p/>"),
    Extra = #{~"cache-control" => ~"public, max-age=60"},
    {ok, Req} = datastar_nova:handle(
        {datastar, 200, Extra, Events},
        undefined,
        ?EMPTY_REQ
    ),
    ?assertEqual(
        ~"public, max-age=60",
        maps:get(~"cache-control", maps:get(resp_headers, Req))
    ).

handle_body_concatenates_multiple_events_test() ->
    Events = [
        datastar:patch_elements(~"<p>one</p>"),
        datastar:patch_signals(#{n => 1})
    ],
    {ok, Req} = datastar_nova:handle({datastar, Events}, fun erlang:date/0, ?EMPTY_REQ),
    Body = maps:get(resp_body, Req),
    ?assertMatch({_, _}, binary:match(Body, ~"<p>one</p>")),
    ?assertMatch({_, _}, binary:match(Body, ~"datastar-patch-signals")).

%% -- read_signals/1 -----------------------------------------------------------
%%
%% read_signals/1 depends on cowboy_req:match_qs/2 and cowboy_req:read_body/1,
%% which we mock by giving the Req a shape that triggers the GET branch and
%% using the cowboy qs parser's behavior with a plain map.
%%
%% For the body case we can't easily unit-test without Cowboy running; the
%% logic is trivial (read body, hand to datastar:read_signals/1) and covered
%% indirectly by the datastar tests.

read_signals_get_missing_test() ->
    Req = #{method => ~"GET", qs => <<>>},
    {Result, _Req1} = datastar_nova:read_signals(Req),
    ?assertEqual({error, missing}, Result).

read_signals_get_decodes_query_test() ->
    Req = #{method => ~"GET", qs => <<"datastar=%7B%22n%22%3A5%7D">>},
    {Result, _Req1} = datastar_nova:read_signals(Req),
    ?assertEqual({ok, #{~"n" => 5}}, Result).

%% When nova_request_plugin has already decoded the body into `json`
%% (consuming it), use that map rather than re-reading the empty body.
read_signals_uses_predecoded_json_test() ->
    Req = #{method => ~"POST", json => #{~"type" => ~"email", ~"value" => ~"a@b.com"}},
    {Result, _Req1} = datastar_nova:read_signals(Req),
    ?assertEqual({ok, #{~"type" => ~"email", ~"value" => ~"a@b.com"}}, Result).

read_signals_get_invalid_json_test() ->
    Req = #{method => ~"GET", qs => ~"datastar=%7B%22n%22%3A"},
    {Result, _Req1} = datastar_nova:read_signals(Req),
    ?assertMatch({error, {invalid_json, _}}, Result).

read_signals_get_not_an_object_test() ->
    Req = #{method => ~"GET", qs => ~"datastar=%5B1%5D"},
    {Result, _Req1} = datastar_nova:read_signals(Req),
    ?assertEqual({error, not_an_object}, Result).

%% -- live stream pubsub fan-out ----------------------------------------------
%%
%% publish/2 must reach every process subscribed to the channel, carrying the
%% frame as the envelope payload. That is the contract datastar_nova_stream's
%% loop relies on (it writes #nova_pubsub{payload = Events} to the EventSource).

publish_reaches_subscriber_test() ->
    _ = pg:start(nova_scope),
    ok = datastar_nova:subscribe(test_channel),
    Frame = datastar:patch_elements(~"<li>row</li>", #{selector => ~"#list", mode => append}),
    ok = datastar_nova:publish(test_channel, Frame),
    receive
        #nova_pubsub{channel = test_channel, payload = Payload} ->
            ?assertEqual(Frame, Payload)
    after 1000 ->
        ?assert(false)
    end.

%% -- line endings -------------------------------------------------------------

one_shot_body_keeps_carriage_return_inside_one_event_test() ->
    Events = datastar:patch_elements(~"<pre>one\r\rtwo\r\nthree</pre>"),
    {ok, Req} = datastar_nova:handle({datastar, Events}, undefined, ?EMPTY_REQ),
    ?assertEqual(
        [{~"datastar-patch-elements", ~"<pre>one\n\ntwo\nthree</pre>"}],
        received_patches(maps:get(resp_body, Req))
    ).

live_stream_keeps_carriage_return_inside_one_event_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    _ = pg:start(nova_scope),
    Req = #{pid => self(), streamid => 1, method => ~"GET"},
    InitEvents = datastar:patch_elements(~"<ul id=\"rows\"></ul>"),
    Stream = spawn_link(fun() ->
        datastar_nova_stream:handle(
            {datastar_stream, carriage_return_channel, InitEvents}, undefined, Req
        )
    end),
    receive
        {{_Connection, 1}, {headers, 200, Headers}} ->
            ?assertEqual(~"text/event-stream", maps:get(~"content-type", Headers))
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual(
        [{~"datastar-patch-elements", ~"<ul id=\"rows\"></ul>"}],
        received_patches(written_frame(Stream))
    ),
    ok = datastar_nova:publish(
        carriage_return_channel,
        datastar:patch_elements(~"<li>one\rtwo</li>", #{selector => ~"#rows", mode => append})
    ),
    Published = written_frame(Stream),
    unlink(Stream),
    exit(Stream, kill),
    ?assertEqual(
        [{~"datastar-patch-elements", ~"<li>one\ntwo</li>"}],
        received_patches(Published)
    ).

%% -- errors raised by the SDK -------------------------------------------------

refused_option_raises_before_the_return_handler_test() ->
    ?assertError(
        {invalid_option, selector, line_break},
        datastar_nova:handle(
            {datastar, datastar:patch_elements(~"<p/>", #{selector => ~"#list\n#other"})},
            undefined,
            ?EMPTY_REQ
        )
    ).

refused_argument_raises_in_the_publisher_and_nothing_is_broadcast_test() ->
    _ = pg:start(nova_scope),
    ok = datastar_nova:subscribe(refused_channel),
    ?assertError(
        {invalid_argument, signals, not_json},
        datastar_nova:publish(refused_channel, datastar:patch_signals(~"{\"count\":"))
    ),
    receive
        #nova_pubsub{channel = refused_channel} -> ?assert(false)
    after 0 ->
        ok
    end.

%% -- helpers ------------------------------------------------------------------

written_frame(Stream) ->
    receive
        {{_Connection, 1}, {data, Stream, nofin, Frame}} ->
            Stream ! {data_ack, self()},
            Frame
    after 1000 ->
        error(no_frame_written)
    end.

%% Reads a stream the way an SSE client does: a line ends at CRLF, CR or LF
%% and a blank line dispatches the event. Returns the type of each event
%% with the HTML a Datastar client rebuilds from its `elements` lines.
received_patches(Stream) ->
    Lines = binary:split(iolist_to_binary(Stream), [~"\r\n", ~"\r", ~"\n"], [global]),
    dispatched_events(Lines, ~"", []).

dispatched_events([], _Type, _ElementsLines) ->
    [];
dispatched_events([~"" | Rest], _Type, []) ->
    dispatched_events(Rest, ~"", []);
dispatched_events([~"" | Rest], Type, ElementsLines) ->
    Html = iolist_to_binary(lists:join(~"\n", lists:reverse(ElementsLines))),
    [{Type, Html} | dispatched_events(Rest, ~"", [])];
dispatched_events([Line | Rest], Type, ElementsLines) ->
    case binary:split(Line, ~": ") of
        [~"event", NewType] ->
            dispatched_events(Rest, NewType, ElementsLines);
        [~"data", Data] ->
            dispatched_events(Rest, Type, elements_line(Data) ++ ElementsLines);
        _OtherLine ->
            dispatched_events(Rest, Type, ElementsLines)
    end.

elements_line(Data) ->
    case binary:split(Data, ~" ") of
        [~"elements", HtmlLine] -> [HtmlLine];
        _OtherData -> []
    end.
