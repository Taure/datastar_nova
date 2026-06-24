# datastar_nova

[Nova](https://novaframework.org) integration for the
[datastar](https://github.com/Taure/datastar) Erlang SDK.

- Registers a Nova controller return handler for `{datastar, ...}`
  tuples — drop patches into your response by returning a list.
- Reads Datastar signals out of any Nova request (GET query or body).
- **Live-stream** (`{datastar_stream, ...}`) — a long-lived SSE that
  pushes `nova_pubsub`-published frames to connected pages.
- Both one-shot and live-stream modes shipped; see
  [ARCHITECTURE.md](ARCHITECTURE.md).

## Install

```erlang
{deps, [
    {datastar_nova,
        {git, "https://github.com/Taure/datastar_nova.git", {branch, "main"}}}
]}.
```

Include `datastar_nova` in the `applications` list of your `.app.src`;
the application's start hook registers the Nova handler on boot.

## Controller usage

```erlang
-module(my_controller).
-export([add_todo/1]).

add_todo(Req0) ->
    {{ok, #{~"title" := Title}}, Req1} = datastar_nova:read_signals(Req0),
    Todo = todos:insert(Title),
    {datastar, [
        datastar:patch_elements(render_todo(Todo),
                                 #{selector => ~"#list", mode => append}),
        datastar:patch_signals(#{~"input" => ~""})
    ]}.
```

Variants:

```erlang
{datastar, Events}                              %% status 200
{datastar, 202, Events}                         %% custom status
{datastar, 200, #{~"x-trace-id" => Tid}, Events}  %% custom status + headers
```

## Live stream (server-push)

A controller that returns `{datastar_stream, Channel}` holds the
connection open as an SSE and writes every frame published to the
`nova_pubsub` `Channel`. Pass initial events as a third element to paint
the page on connect.

```erlang
%% GET /sse/messages — opened from the page with data-init="@get('/sse/messages')"
stream(_Req) ->
    {datastar_stream, messages, render_all()}.
```

Publish from anywhere — every connected stream on the channel writes it:

```erlang
%% e.g. when a new message arrives
datastar_nova:publish(messages,
    datastar:patch_elements(render_row(Msg),
                            #{selector => ~"#messages", mode => append})).
```

Serve the page HTML (and its assets) with `Cache-Control: no-store`, and
open the stream with Datastar's `data-init` (v1 has no `data-on-load`).

## Reading signals

```erlang
{Result, Req1} = datastar_nova:read_signals(Req0),
case Result of
    {ok, #{~"count" := N}} -> do_something(N, Req1);
    {error, _} -> {status, 400, Req1}
end.
```

For `GET` requests the signals come from the `datastar` query
parameter. For other methods they come from the body — that consumes
the body, so **thread the returned `Req1`** through the rest of your
controller.

## One-shot vs streaming

The v1 handler delivers a batch of events as a single HTTP response and
closes. That covers the HTMX-style pattern that dominates Datastar
usage: action → N patches → done.

For long-lived server-push (dashboards, live counters, collaborative
views) the right pattern is a Cowboy loop-handler upgrade from Nova's
`init/2` path. See [ARCHITECTURE.md](ARCHITECTURE.md).

## License

Apache-2.0.
