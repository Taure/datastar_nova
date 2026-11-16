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
closes. That covers action → patches → done flows.

For long-lived server-push (live dashboards, PubSub-driven updates), a
controller returns `{datastar_stream, Channel}` and `datastar_nova_stream`
holds the connection open, writing every frame published with
`publish/2`. See that module and `ARCHITECTURE.md`.

## Errors

Events are built by the caller, with the builders of `datastar`, before
this module sees them. From `datastar` v0.1.0 a builder raises
`error:{invalid_option, Option, Reason}` or
`error:{invalid_argument, Argument, Reason}` for a value it cannot
write; the documentation of the `datastar` module lists every reason.
Nothing here catches or rewrites those errors:

- A controller that builds the events of `{datastar, ...}`, or the
  initial events of `{datastar_stream, Channel, InitEvents}`, raises
  before it returns, so no return handler is called. Nova logs the
  crash and answers with status 500.
- A process that builds the events in the argument of `publish/2`
  raises, and nothing is broadcast. Streams that are open on the
  channel are not affected.

Neither error holds the value that was refused. A `selector` or `id`
taken from a request is refused when it has a line break or a NUL byte
in it, so check such a value first, or catch the error and answer with
status 400.

`handle/3` and `publish/2` take events that are already built and
write them as given. `read_signals/1` reads untrusted input and returns
`{error, Reason}` for a payload that is not a JSON object.

## Line endings

`\r\n`, `\r` and `\n` each end a line in HTML, a script and
pre-encoded signals. Text with a carriage return in it stays inside
its event, and the browser receives every line break as `\n`.
""".

-export([register/0, handle/3, read_signals/1, subscribe/1, publish/2]).

-doc """
Register the `datastar` return tag with Nova's handler registry.

Called automatically from `datastar_nova_app:start/2`. Exposed so
applications that don't include `datastar_nova` in their release can
still call it explicitly.
""".
-spec register() -> ok | {error, atom()}.
register() ->
    %% Register explicit /3 funs. Nova invokes return-handlers with 3 args
    %% (RetObj, Callback, Req); its `{Mod, Fun}` form wraps to arity /4, which
    %% mismatches and crashes with badarity on the current Nova master.
    _ = nova_handlers:register_handler(datastar, fun ?MODULE:handle/3),
    nova_handlers:register_handler(datastar_stream, fun datastar_nova_stream:handle/3).

-doc """
Subscribe the calling process to a `nova_pubsub` channel.

Rarely needed directly - `datastar_nova_stream` joins the channel for
you. Exposed for processes that want to observe a channel themselves.
""".
-spec subscribe(atom()) -> ok.
subscribe(Channel) ->
    nova_pubsub:join(Channel).

-doc """
Publish Datastar events to every live stream on a channel.

`Events` is any `iodata()` - typically `datastar:patch_elements/1,2` or
`datastar:patch_signals/1,2` output. Call from anywhere in the app; each
connected `datastar_nova_stream` on `Channel` writes the frame to its
`EventSource`.

`Events` is broadcast as given. A builder that raises does so in the
calling process, before anything is broadcast.
""".
-spec publish(atom(), iodata()) -> ok.
publish(Channel, Events) ->
    nova_pubsub:broadcast(Channel, ~"datastar", Events).

-doc """
Nova handler for `{datastar, ...}` controller returns.

Accepts three tuple shapes:

- `{datastar, Events}` — status 200, default SSE headers only.
- `{datastar, StatusCode, Events}` — custom status code.
- `{datastar, StatusCode, Headers, Events}` — custom status + extra
  response headers merged over the SSE defaults.

`Events` is anything `iodata()`-compatible: typically a list of
`datastar:patch_elements/...` / `datastar:patch_signals/...` outputs.

`Events` becomes the response body as given. A builder that raises
does so in the controller, which Nova answers with status 500, and
this handler is not called.
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

For other methods the signal store is the JSON body. If Nova has already
decoded it (the `nova_request_plugin` with `decode_json_body => true`
puts it under the `json` key, consuming the body), that map is used
directly. Otherwise the body is read and decoded — so it works whether
or not the json-decode plugin is enabled.

Returns `{Result, Req}` — thread the returned `Req` through the rest of
your controller so subsequent `cowboy_req:read_body/1` calls don't
re-consume.

`Result` is `{error, missing}` for a `GET` without the `datastar`
parameter, `{error, {invalid_json, Reason}}` for a payload that is not
JSON and `{error, not_an_object}` for JSON that is not an object.
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
read_signals(#{json := Signals} = Req) when is_map(Signals) ->
    {{ok, Signals}, Req};
read_signals(Req) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    {datastar:read_signals(Body), Req1}.
