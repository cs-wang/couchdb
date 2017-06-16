% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(ddoc_cache_refresher_test).


-include_lib("eunit/include/eunit.hrl").
-include("ddoc_cache_test.hrl").


key() ->
    {ddoc_cache_entry_custom, {<<"dbname_here">>, ?MODULE}}.


setup() ->
    Ctx = test_util:start_couch(),
    ets:new(?CACHE, [public, named_table, set, {keypos, #entry.key}]),
    ets:insert(?CACHE, #entry{key = key(), val = bang}),
    meck:new(ddoc_cache_lru, [passthrough]),
    meck:new(ddoc_cache_entry, [passthrough]),
    Ctx.


teardown(Ctx) ->
    meck:unload(),
    ets:delete(?CACHE),
    test_util:stop_couch(Ctx).


refresher_test_() ->
    {
        foreach,
        fun setup/0,
        fun teardown/1,
        [
            fun handles_error/0,
            fun refresh_on_timeout/0,
            fun refresh_once/0,
            fun dies_on_missing_entry/0,
            fun dies_on_evicted/0
        ]
    }.


handles_error() ->
    meck:expect(ddoc_cache_entry, spawn_refresher, fun(_) ->
        throw(foo)
    end),
    {Pid, Ref} = spawn_refresher(),
    ddoc_cache_refresher:refresh(Pid),
    receive
        {'DOWN', Ref, _, _, {throw, foo, _}} ->
            ok
    end.


refresh_on_timeout() ->
    meck:expect(ddoc_cache_entry, spawn_refresher, fun(Key) ->
        Ref = erlang:make_ref(),
        self() ! {'DOWN', Ref, process, pid, {open_ok, Key, {ok, zot}}},
        {self(), Ref}
    end),
    meck:expect(ddoc_cache_lru, update, fun(_, zot) ->
        ok
    end),
    {Pid, _} = spawn_refresher(),
    ets:update_element(?CACHE, key(), {#entry.pid, Pid}),
    % This is the assertion that if we wait long enough
    % the update will be called.
    meck:wait(ddoc_cache_lru, update, ['_', '_'], 1000),
    ?assert(is_process_alive(Pid)),
    ddoc_cache_refresher:stop(Pid).


refresh_once() ->
    Counter = spawn_counter(),
    meck:expect(ddoc_cache_entry, spawn_refresher, fun(Key) ->
        Ref = erlang:make_ref(),
        Count = get_count(Counter),
        self() ! {'DOWN', Ref, process, pid, {open_ok, Key, {ok, Count}}},
        {self(), Ref}
    end),
    meck:expect(ddoc_cache_lru, update, fun(_, 1) ->
        ok
    end),
    {Pid, _} = spawn_refresher(),
    ets:update_element(?CACHE, key(), {#entry.pid, Pid}),
    erlang:suspend_process(Pid),
    lists:foreach(fun(_) ->
        ddoc_cache_refresher:refresh(Pid)
    end, lists:seq(1, 100)),
    erlang:resume_process(Pid),
    % This is the assertion that if we wait long enough
    % the update will be called.
    meck:wait(ddoc_cache_lru, update, ['_', '_'], 1000),
    ?assert(is_process_alive(Pid)),
    ddoc_cache_refresher:stop(Pid).


dies_on_missing_entry() ->
    meck:expect(ddoc_cache_entry, spawn_refresher, fun(Key) ->
        Ref = erlang:make_ref(),
        self() ! {'DOWN', Ref, process, pid, {open_ok, Key, {ok, zot}}},
        {self(), Ref}
    end),
    {Pid, _} = spawn_refresher(),
    ets:delete(?CACHE, key()),
    ddoc_cache_refresher:refresh(Pid),
    receive
        {'DOWN', _, _, Pid, normal} ->
            ok
    end.


dies_on_evicted() ->
    meck:expect(ddoc_cache_entry, spawn_refresher, fun(Key) ->
        Ref = erlang:make_ref(),
        self() ! {'DOWN', Ref, process, pid, {open_ok, Key, {ok, zot}}},
        {self(), Ref}
    end),
    meck:expect(ddoc_cache_lru, update, fun(_, zot) ->
        evicted
    end),
    {Pid, _} = spawn_refresher(),
    ets:update_element(?CACHE, key(), {#entry.pid, Pid}),
    ddoc_cache_refresher:refresh(Pid),
    receive
        {'DOWN', _, _, Pid, normal} ->
            ok
    end.


spawn_refresher() ->
    erlang:spawn_monitor(ddoc_cache_refresher, init, [{self(), key(), 100}]).


spawn_counter() ->
    erlang:spawn_link(fun do_counting/0).


get_count(Pid) ->
    Pid ! {get, self()},
    receive
        {count, Pid, N} ->
            N
    end.


do_counting() ->
    do_counting(0).


do_counting(N) ->
    receive
        {get, From} ->
            From ! {count, self(), N + 1},
            do_counting(N + 1)
    end.