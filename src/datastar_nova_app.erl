-module(datastar_nova_app).
-moduledoc false.

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    _ = datastar_nova:register(),
    datastar_nova_sup:start_link().

stop(_State) ->
    ok.
