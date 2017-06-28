-module(ddoc_cache_speed).

-export([
    go/1,
    recover/1
]).


-include("ddoc_cache.hrl").


go(WorkerCount) when is_integer(WorkerCount), WorkerCount > 0 ->
    spawn_workers(WorkerCount),
    report().


recover(DbName) ->
    {ok, {stuff, DbName}}.


spawn_workers(0) ->
    ok;

spawn_workers(WorkerCount) ->
    Self = self(),
    WorkerDb = list_to_binary(integer_to_list(WorkerCount)),
    spawn_link(fun() ->
        do_work(Self, WorkerDb, 0)
    end),
    spawn_workers(WorkerCount - 1).


do_work(Parent, WorkerDb, Count) when Count >= 25 ->
    Parent ! {done, Count},
    do_work(Parent, WorkerDb, 0);

do_work(Parent, WorkerDb, Count) ->
    {ok, _} = ddoc_cache:open_custom(WorkerDb, ?MODULE),
    do_work(Parent, WorkerDb, Count + 1).


report() ->
    report(os:timestamp(), 0).


report(Start, Count) ->
    Now = os:timestamp(),
    case timer:now_diff(Now, Start) of
        N when N > 1000000 ->
            {_, MQL} = process_info(whereis(ddoc_cache_lru), message_queue_len),
            ProcCount = erlang:system_info(process_count),
            CacheSize = ets:info(?CACHE, size),
            LRUSize = ets:info(?LRU, size),
            io:format("~p ~p ~p ~p ~p~n", [Count, MQL, ProcCount, CacheSize, LRUSize]),
            report(Now, 0);
        _ ->
            receive
                {done, Done} ->
                    report(Start, Count + Done)
            after 100 ->
                report(Start, Count)
            end
    end.

