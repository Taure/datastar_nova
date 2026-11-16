-module(datastar_nova_stream).
-moduledoc """
Live-stream (server-push) transport for Datastar over Nova.

A controller returns `{datastar_stream, Channel}` (or
`{datastar_stream, Channel, InitEvents}`); the return-handler here
`stream_reply`s the SSE headers, joins the `nova_pubsub` channel, sends
any initial events, and then **holds the connection** in a receive loop,
writing every published frame to the open `EventSource` and never
returning - so Nova's buffered `render_response/2` (which would reply a
second time and crash) never runs.

Publish frames from anywhere in the app with
`datastar_nova:publish(Channel, Events)`; every connected stream on the
channel writes them. On client disconnect the next `stream_body` throws,
the loop stops, and the request process exits.

A keepalive comment (`: ping`) is sent on idle to defeat proxy idle
timeouts. The handler is registered (as an explicit `fun/3`) by
`datastar_nova:register/0`.

Initial and published events are written as given. They are built by
the controller and by the caller of `datastar_nova:publish/2`, so a
`datastar` builder that raises does so there and never in the stream.
""".

-include_lib("nova/include/nova_pubsub.hrl").

-export([handle/3]).

-define(PING_MS, 25000).

-spec handle(Return, function(), Req) -> {ok, Req} when
    Return ::
        {datastar_stream, atom()}
        | {datastar_stream, atom(), iodata()},
    Req :: cowboy_req:req().
handle({datastar_stream, Channel}, Callback, Req) ->
    handle({datastar_stream, Channel, []}, Callback, Req);
handle({datastar_stream, Channel, InitEvents}, _Callback, Req0) ->
    Headers = maps:from_list(datastar:sse_headers()),
    Req = cowboy_req:stream_reply(200, Headers, Req0),
    ok = nova_pubsub:join(Channel),
    case send(Req, InitEvents) of
        stop -> {ok, Req};
        ok -> loop(Req)
    end.

loop(Req) ->
    receive
        #nova_pubsub{payload = Events} ->
            case send(Req, Events) of
                ok -> loop(Req);
                stop -> {ok, Req}
            end;
        _Other ->
            loop(Req)
    after ?PING_MS ->
        case send(Req, <<": ping\n\n">>) of
            ok -> loop(Req);
            stop -> {ok, Req}
        end
    end.

send(_Req, []) ->
    ok;
send(Req, Frame) ->
    try
        ok = cowboy_req:stream_body(Frame, nofin, Req),
        ok
    catch
        _:_ -> stop
    end.
