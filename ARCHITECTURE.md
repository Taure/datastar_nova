# Architecture

`datastar_nova` exposes Datastar over a Nova stack. This document
explains the integration model, the constraints Nova imposes on it, and
how we plan to reach full protocol coverage (including long-lived
server-push streams).

## Summary

| Mode | Transport | Status |
|---|---|---|
| **One-shot** — action request → N patches → close | single HTTP response, body is a concatenated SSE stream | **Shipped (v1)** |
| **Live stream** — long-lived server-push | Cowboy loop handler writing to a streamed response | **v2 (planned)** |
| **PubSub fan-out** — one source → many subscribers | loop handlers subscribe to `nova_pubsub` topics | **v2 (planned)** |

V1 covers the action/response flows that dominate the Datastar HTMX-style
use case. V2 covers dashboards, live counters, and collaborative views.

---

## The core constraint: Nova's response path

Nova dispatches a request by calling the controller, matching the return
tuple to a registered handler, and finally running `render_response/2`:

```erlang
render_response(Req = #{resp_status_code := StatusCode}, Env) ->
    Req0 = cowboy_req:reply(StatusCode, Req),
    {ok, Req0, Env};
render_response(Req, Env) ->
    Req0 = cowboy_req:reply(200, Req),
    {ok, Req0, Env}.
```

`cowboy_req:reply/2` commits a **single buffered HTTP response** from
the `resp_body` + `resp_headers` + `resp_status_code` that the handler
set on the `Req` map. That is:

- incompatible with `cowboy_req:stream_reply/3` — calling `reply/2`
  after `stream_reply/3` crashes with `{response_already_sent, …}`;
- the right fit for one-shot responses with a known full body.

Real SSE requires `stream_reply/3` + `stream_body/3` because the server
progressively writes events as they happen. We cannot use it from inside
a normal Nova controller handler, so we work **with** Nova's
single-reply path for v1, and **around** it for v2.

---

## Mode 1 — One-shot (v1, shipped)

### Contract

Controller returns one of:

```erlang
{datastar, Events}
{datastar, StatusCode, Events}
{datastar, StatusCode, ExtraHeaders, Events}
```

`Events` is any `iodata()` — typically a list of `datastar:patch_*/1,2`
outputs. `ExtraHeaders` is a map merged over the Datastar SSE defaults.

### Implementation

`datastar_nova:handle/3` is the registered Nova handler:

1. Flatten `Events` to a single binary body (`iolist_to_binary/1`).
2. Set SSE headers (`text/event-stream`, `no-cache`, `keep-alive`) plus
   any extras.
3. Set the status code and return `{ok, Req}` — Nova's normal
   `render_response/2` does the buffered reply.

### What this covers

- Form submission → server returns a batch of patches → browser applies
  them and closes the `EventSource`.
- Any click/keypress action that yields N patches then ends.

This is the dominant Datastar pattern for HTMX-style UIs. Example:

```erlang
add_todo(Req0) ->
    {{ok, #{~"title" := Title}}, Req1} = datastar_nova:read_signals(Req0),
    Todo = todos:insert(Title),
    {datastar, [
        datastar:patch_elements(render_todo(Todo), #{selector => ~"#list", mode => append}),
        datastar:patch_signals(#{~"input" => ~""})
    ]}.
```

### Limitations

- One HTTP request = one batch. The server cannot push further events
  after returning; the client must make a new request.
- No server-initiated updates (notifications, live counters, presence).
- OK in practice: the browser's `EventSource` will reconnect on close,
  but the one-shot body pattern is not a substitute for a real stream.

---

## Mode 2 — Live stream via loop-handler upgrade (v2, planned)

### The upgrade path Nova already supports

`nova_handler:execute/2` for `init/2`-style controllers:

```erlang
try Handler:init(Req, Arguments) of
    {ok, Req2, _State} ->
        Result = terminate(normal, Req2, fun Handler:dummy/1),
        {ok, Req2, Env#{result => Result}};
    {Mod, Req2, State} ->
        Mod:upgrade(Req2, Env, Handler, State);
    {Mod, Req2, State, Opts} ->
        Mod:upgrade(Req2, Env, Handler, State, Opts)
```

When a controller's `init/2` returns `{Mod, Req, State}`, Nova calls
`Mod:upgrade/4`. Cowboy's `cowboy_loop` implements exactly that
contract. That is Nova's escape hatch: **by returning
`{cowboy_loop, Req, State}` from `init/2`, we bypass `render_response/2`
entirely** and let Cowboy own the connection.

### Planned shape of the module

`datastar_nova_stream` — a Cowboy sub-protocol handler:

```erlang
-module(datastar_nova_stream).
-behaviour(cowboy_loop).  % informal — cowboy_loop is contract-based

%% Controllers use `init/2` and return:
%%   {datastar_nova_stream, Req, UserInit, UserState}
init(Req0, UserModArgs) ->
    Req1 = cowboy_req:stream_reply(200, maps:from_list(datastar:sse_headers()), Req0),
    UserState = apply_init(UserModArgs, Req1),
    {cowboy_loop, Req1, UserState, hibernate}.

info(Message, Req, UserState) ->
    case user_handle_info(Message, UserState) of
        {events, Events, NewState} ->
            ok = cowboy_req:stream_body(Events, nofin, Req),
            {ok, Req, NewState, hibernate};
        {stop, NewState} ->
            {stop, Req, NewState}
    end.
```

User routes declare:

```erlang
{"/ticker", datastar_nova_stream, [{user_module, my_ticker}]}
```

And `my_ticker` exposes `init/1` + `handle_info/2` the usual Erlang way.

### PubSub integration

`nova_pubsub` is built on `pg`. A loop handler subscribes to a topic
during init; every `{pubsub_message, Topic, Events}` arriving in
`info/3` becomes a `stream_body` write. One-liner helper:

```erlang
datastar_nova:subscribe(Topic) -> ok.  %% from inside init/1
datastar_nova:publish(Topic, Events) -> ok.  %% from anywhere in the app
```

This gives us fan-out: a single game-state or chat-room update produces
one PubSub broadcast, every connected loop handler writes it to its own
`EventSource`.

### Back-pressure and timeouts

- `cowboy_loop` supports `hibernate` (memory-friendly idle) and idle
  timeouts via the upgrade opts.
- For idle connections we send an SSE comment (`: ping\n\n`) every ~25s
  to defeat proxy idle timeouts (AWS ALB default 60s, Cloudflare 100s).
- If a client is slow, Cowboy's own socket buffer provides natural
  back-pressure; `stream_body` returns when the kernel write completes.

### What this covers

- Long-lived dashboards: open the page, server pushes updates until the
  tab closes.
- Collaborative editing: every user subscribes to the document topic.
- Progress/notification streams.
- Everything mode 1 does plus everything mode 1 can't.

---

## Mode 3 — Reading signals

Datastar sends the client signal store on every action:

- `GET` requests → URL-encoded JSON in the `datastar` query parameter.
- Other methods → JSON body.

`datastar_nova:read_signals/1` handles both. For non-`GET` it consumes
the body via `cowboy_req:read_body/1`, so it returns `{Result, Req}` —
the caller must thread the returned `Req` through.

---

## Why not just use real streaming for everything?

Because Nova's buffered reply is deeply ingrained in the handler
registry and we don't want to fork it. One-shot covers a huge slice of
the Datastar use case (actions → patches) without any of the
complexity of a persistent process, sticky sessions, or proxy
back-pressure handling. Ship it simple, upgrade the long-lived case
when it's actually needed.

---

## Non-goals

- **Replacing Arizona.** Arizona is the WebSocket + live-process
  LiveView mode for Nova. Datastar mode is for HTMX-style,
  stateless-per-request UIs. Two modes, two audiences.
- **A reactive framework.** Datastar and `datastar_nova` do not own UI
  state on the server. Controllers compute patches from data; we write
  them to the wire.
- **Diff engines.** Users send hand-built HTML fragments. No template
  diffing, no virtual DOM.

---

## Open questions for v2

1. **Signal-aware stream handlers.** The browser resends the signal
   store on every action. For a loop handler, we need a way to receive
   "the client's current signals" alongside the initial request —
   probably out of band via a follow-up POST that publishes to the
   topic.
2. **Authenticated SSE.** Cookie auth works out of the box; token auth
   needs Datastar's header plumbing (which exists). Document the
   pattern.
3. **Reconnect semantics.** Use `Last-Event-ID` to allow resuming a
   stream after drop. The SDK side of this exists (`id:` fields on
   events); the loop handler needs to understand the header and replay.
