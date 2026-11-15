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

## Errors and line endings

`datastar_nova` builds against
[`datastar` v0.1.0](https://github.com/Taure/datastar/blob/v0.1.0/CHANGELOG.md).
The SDK needs OTP 28 or later, so `datastar_nova` does too.

Your code builds the events, with `datastar:patch_elements/1,2` and the
other builders, before `datastar_nova` sees them. From v0.1.0 a builder
raises `error:{invalid_option, Option, Reason}` or
`error:{invalid_argument, Argument, Reason}` for a value it cannot
write: an option key it does not take, a `selector` or `id` with a line
break in it, pre-encoded signals that are not one JSON value, a script
that contains `</script`. The SDK's module documentation lists every
reason. `datastar_nova` neither catches nor rewrites these errors:

| Where the event is built | What happens |
|---|---|
| In a controller, for `{datastar, ...}` or for the initial events of `{datastar_stream, ...}` | The controller raises and no return handler is called. Nova logs the crash and answers with status 500. |
| In the argument of `datastar_nova:publish/2` | The publishing process raises and nothing is broadcast. Streams that are open on the channel are not affected. |

Neither error holds the value that was refused. If a `selector` or an
`id` comes from a request (a signal, a path binding, a query value),
check it first, or catch the error and answer with status 400:

```erlang
remove_row(#{bindings := #{~"id" := RowId}}) ->
    try datastar:remove_elements([~"#row-", RowId]) of
        Event -> {datastar, Event}
    catch
        error:{invalid_option, selector, _Reason} -> {status, 400}
    end.
```

`datastar_nova:read_signals/1` reads untrusted input and returns
`{error, missing}`, `{error, {invalid_json, Reason}}` or
`{error, not_an_object}` for a payload it cannot use.

`\r\n`, `\r` and `\n` each end a line in streamed HTML, in a script and
in pre-encoded signals. Text with a carriage return in it stays inside
its event, and the browser receives every line break as `\n`.

## One-shot vs streaming

The v1 handler delivers a batch of events as a single HTTP response and
closes. That covers the HTMX-style pattern that dominates Datastar
usage: action → N patches → done.

For long-lived server-push (dashboards, live counters, collaborative
views) the right pattern is a Cowboy loop-handler upgrade from Nova's
`init/2` path. See [ARCHITECTURE.md](ARCHITECTURE.md).

## License

Apache-2.0.
