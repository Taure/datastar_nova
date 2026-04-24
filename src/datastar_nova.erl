-module(datastar_nova).
-moduledoc """
Nova integration for [Datastar](https://data-star.dev).

Registers a Nova controller return handler for `{datastar, ...}` tuples,
and exposes a helper to read Datastar signals out of an incoming Nova
request (query string for `GET`, body otherwise).

## Controller usage

    my_controller(Req) ->
        {datastar, [
            datastar:patch_elements(~"<div id=\"status\">ok</div>"),
            datastar:patch_signals(#{count => 5})
        ]}.

Or with a custom status / extra headers:

    {datastar, 200, #{~"x-trace-id" => TraceId}, Events}

## Reading signals

    {Result, Req1} = datastar_nova:read_signals(Req0),
    case Result of
        {ok, #{~"count" := N}} -> ...;
        {error, _}             -> ...
    end.

The returned `Req1` must be threaded through — when signals come from
the body we consume it via `cowboy_req:read_body/1`, which is a
one-shot.

## One-shot vs streaming

`{datastar, Events}` delivers all events in a single HTTP response and
closes. That covers action → patches → done flows. For long-lived
server-push streams (live dashboards, PubSub-driven updates),
see `ARCHITECTURE.md` in this repo — real streaming requires Cowboy's
loop-handler upgrade path, which is planned as a v2 feature.
""".

-export([register/0, handle/3, read_signals/1]).

-doc """
Register the `datastar` return tag with Nova's handler registry.

Called automatically from `datastar_nova_app:start/2`. Exposed so
applications that don't include `datastar_nova` in their release can
still call it explicitly.
""".
-spec register() -> ok | {error, atom()}.
register() ->
    nova_handlers:register_handler(datastar, {?MODULE, handle}).

-doc """
Nova handler for `{datastar, ...}` controller returns.

Accepts three tuple shapes:

- `{datastar, Events}` — status 200, default SSE headers only.
- `{datastar, StatusCode, Events}` — custom status code.
- `{datastar, StatusCode, Headers, Events}` — custom status + extra
  response headers merged over the SSE defaults.

`Events` is anything `iodata()`-compatible: typically a list of
`datastar:patch_elements/...` / `datastar:patch_signals/...` outputs.
""".
-spec handle(Return, function(), Req) -> {ok, Req} when
    Return ::
        {datastar, iodata()}
        | {datastar, pos_integer(), iodata()}
        | {datastar, pos_integer(), map(), iodata()},
    Req :: cowboy_req:req().
handle({datastar, Events}, Callback, Req) ->
    handle({datastar, 200, #{}, Events}, Callback, Req);
handle({datastar, StatusCode, Events}, Callback, Req) when is_integer(StatusCode) ->
    handle({datastar, StatusCode, #{}, Events}, Callback, Req);
handle({datastar, StatusCode, ExtraHeaders, Events}, _Callback, Req) ->
    DefaultHeaders = maps:from_list(datastar:sse_headers()),
    Headers = maps:merge(DefaultHeaders, ExtraHeaders),
    Body = iolist_to_binary(Events),
    Req1 = cowboy_req:set_resp_headers(Headers, Req),
    Req2 = cowboy_req:set_resp_body(Body, Req1),
    {ok, Req2#{resp_status_code => StatusCode}}.

-doc """
Read Datastar signals out of a Nova request.

For `GET` requests, decodes the `datastar` query parameter.
For all other methods, reads the body (consuming it) and decodes.

Returns `{Result, Req}` — thread the returned `Req` through the rest of
your controller so subsequent `cowboy_req:read_body/1` calls don't
re-consume.
""".
-spec read_signals(Req) -> {Result, Req} when
    Result ::
        {ok, map()}
        | {error, missing | {invalid_json, term()} | not_an_object},
    Req :: cowboy_req:req().
read_signals(#{method := ~"GET"} = Req) ->
    case cowboy_req:match_qs([{datastar, [], undefined}], Req) of
        #{datastar := undefined} -> {{error, missing}, Req};
        #{datastar := Json} -> {datastar:read_signals(Json), Req}
    end;
read_signals(Req) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    {datastar:read_signals(Body), Req1}.
