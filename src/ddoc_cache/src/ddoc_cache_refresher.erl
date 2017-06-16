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

-module(ddoc_cache_refresher).


-export([
    spawn_link/2,
    refresh/1,
    stop/1
]).


-export([
    init/1
]).


-include("ddoc_cache.hrl").


spawn_link(Key, Interval) ->
    proc_lib:spawn_link(?MODULE, init, [{self(), Key, Interval}]).


refresh(Pid) ->
    Pid ! refresh.


stop(Pid) ->
    unlink(Pid),
    Pid ! stop.


init({Parent, Key, Interval}) ->
    erlang:monitor(process, Parent),
    try
        loop(Key, Interval)
    catch T:R ->
        S = erlang:get_stacktrace(),
        exit({T, R, S})
    end.


loop(Key, Interval) ->
    receive
        refresh ->
            do_refresh(Key, Interval);
        stop ->
            ok
    after Interval ->
        do_refresh(Key, Interval)
    end.


do_refresh(Key, Interval) ->
    drain_refreshes(),
    {_Pid, Ref} = ddoc_cache_entry:spawn_refresher(Key),
    receive
        {'DOWN', Ref, _, _, Resp} ->
            case Resp of
                {open_ok, Key, {ok, Val}} ->
                    maybe_update(Key, Val, Interval);
                _Else ->
                    ddoc_cache_lru:remove(Key)
            end
    end.


drain_refreshes() ->
    receive
        refresh ->
            drain_refreshes()
    after 0 ->
        ok
    end.


maybe_update(Key, Val, Interval) ->
    case ets:lookup(?CACHE, Key) of
        [] ->
            ok;
        [#entry{val = Val}] ->
            ?EVENT(update_noop, Key),
            loop(Key, Interval);
        [#entry{pid = Pid}] when Pid == self() ->
            case ddoc_cache_lru:update(Key, Val) of
                ok ->
                    loop(Key, Interval);
                evicted ->
                    ok
            end
    end.
