-module(datastar_nova_tests).
-eqwalizer(ignore).

-include_lib("eunit/include/eunit.hrl").

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
