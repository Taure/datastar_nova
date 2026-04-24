# datastar_nova

[Nova](https://novaframework.org) integration for the
[datastar](https://github.com/Taure/datastar) Erlang SDK.

- Registers a Nova controller return handler for `{datastar, ...}`
  tuples — drop patches into your response by returning a list.
- Reads Datastar signals out of any Nova request (GET query or body).
- One-shot mode shipped; live-stream mode documented in
  [ARCHITECTURE.md](ARCHITECTURE.md) and planned for v2.

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
