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

-module(ddoc_cache_lru).
-behaviour(gen_server).
-vsn(1).


-export([
    start_link/0,

    insert/2,
    accessed/1,
    update/2,
    remove/1,
    refresh/2
]).

-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3
]).

-export([
    handle_db_event/3
]).


-include("ddoc_cache.hrl").


-record(st, {
    atimes, % key -> time
    dbs, % dbname -> docid -> key -> []
    time,
    evictor
}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


insert(Key, Val) ->
    gen_server:call(?MODULE, {insert, Key, Val}).


accessed(Key) ->
    gen_server:cast(?MODULE, {accessed, Key}).


update(Key, Val) ->
    gen_server:call(?MODULE, {update, Key, Val}).


remove(Key) ->
    gen_server:call(?MODULE, {remove, Key}).


refresh(DbName, DDocIds) ->
    gen_server:cast(?MODULE, {refresh, DbName, DDocIds}).


init(_) ->
    process_flag(trap_exit, true),
    {ok, ATimes} = khash:new(),
    {ok, Dbs} = khash:new(),
    {ok, Evictor} = couch_event:link_listener(
            ?MODULE, handle_db_event, nil, [all_dbs]
        ),
    {ok, #st{
        atimes = ATimes,
        dbs = Dbs,
        time = 0,
        evictor = Evictor
    }}.


terminate(_Reason, St) ->
    case is_pid(St#st.evictor) of
        true -> exit(St#st.evictor, kill);
        false -> ok
    end,
    ok.


handle_call({insert, Key, Val}, _From, St) ->
    #st{
        atimes = ATimes,
        dbs = Dbs,
        time = Time
    } = St,
    NewTime = Time + 1,
    NewSt = St#st{time = NewTime},
    Pid = ddoc_cache_refresher:spawn_link(Key, ?REFRESH_TIMEOUT),
    true = ets:insert(?CACHE, #entry{key = Key, val = Val, pid = Pid}),
    true = ets:insert(?LRU, {NewTime, Key}),
    ok = khash:put(ATimes, Key, NewTime),
    store_key(Dbs, Key),
    trim(NewSt),
    ?EVENT(inserted, {Key, Val}),
    {reply, ok, NewSt};

handle_call({update, Key, Val}, _From, St) ->
    #st{
        atimes = ATimes
    } = St,
    case khash:lookup(ATimes, Key) of
        {value, _} ->
            ets:update_element(?CACHE, Key, {#entry.val, Val}),
            ?EVENT(updated, {Key, Val}),
            {reply, ok, St};
        not_found ->
            {reply, evicted, St}
    end;

handle_call({remove, Key}, _From, St) ->
    #st{
        atimes = ATimes,
        dbs = Dbs
    } = St,
    case khash:lookup(ATimes, Key) of
        {value, ATime} ->
            [#entry{pid = Pid}] = ets:lookup(?CACHE, Key),
            ddoc_cache_refresher:stop(Pid),
            remove_key(St, Key, ATime),

            DbName = ddoc_cache_entry:dbname(Key),
            DDocId = ddoc_cache_entry:ddocid(Key),
            {value, DDocIds} = khash:lookup(Dbs, DbName),
            {value, Keys} = khash:lookup(DDocIds, DDocId),
            ok = khash:del(Keys, Key),
            case khash:size(Keys) of
                0 -> khash:del(DDocIds, DDocId);
                _ -> ok
            end,
            case khash:size(DDocIds) of
                0 -> khash:del(Dbs, DDocId);
                _ -> ok
            end,

            ?EVENT(removed, Key);
        not_found ->
            ok
    end,
    {reply, ok, St};

handle_call(Msg, _From, St) ->
    {stop, {invalid_call, Msg}, {invalid_call, Msg}, St}.


handle_cast({accessed, Key}, St) ->
    #st{
        atimes = ATimes,
        time = Time
    } = St,
    NewTime = Time + 1,
    case khash:lookup(ATimes, Key) of
        {value, OldTime} ->
            [#entry{pid = Pid}] = ets:lookup(?CACHE, Key),
            true = is_process_alive(Pid),
            true = ets:delete(?LRU, OldTime),
            true = ets:insert(?LRU, {NewTime, Key}),
            ok = khash:put(ATimes, Key, NewTime),
            ?EVENT(accessed, Key);
        not_found ->
            % Likely a client read from the cache while an
            % eviction message was in our mailbox
            ok
    end,
    {noreply, St};

handle_cast({evict, DbName}, St) ->
    gen_server:abcast(mem3:nodes(), ?MODULE, {do_evict, DbName}),
    {noreply, St};

handle_cast({refresh, DbName, DDocIds}, St) ->
    gen_server:abcast(mem3:nodes(), ?MODULE, {do_refresh, DbName, DDocIds}),
    {noreply, St};

handle_cast({do_evict, DbName}, St) ->
    #st{
        dbs = Dbs
    } = St,
    case khash:lookup(Dbs, DbName) of
        {value, DDocIds} ->
            khash:fold(DDocIds, fun(_, Keys, _) ->
                khash:fold(Keys, fun(Key, _, _) ->
                    [#entry{pid = Pid}] = ets:lookup(?CACHE, Key),
                    ddoc_cache_refresher:stop(Pid),
                    remove_key(St, Key)
                end, nil)
            end, nil),
            khash:del(Dbs, DbName),
            ?EVENT(evicted, DbName);
        not_found ->
            ?EVENT(evict_noop, DbName),
            ok
    end,
    {noreply, St};

handle_cast({do_refresh, DbName, DDocIdList}, St) ->
    #st{
        dbs = Dbs
    } = St,
    case khash:lookup(Dbs, DbName) of
        {value, DDocIds} ->
            lists:foreach(fun(DDocId) ->
                case khash:lookup(DDocIds, DDocId) of
                    {value, Keys} ->
                        khash:fold(Keys, fun(Key, _, _) ->
                            [#entry{pid = Pid}] = ets:lookup(?CACHE, Key),
                            ddoc_cache_refresher:refresh(Pid)
                        end, nil);
                    not_found ->
                        ok
                end
            end, [no_ddocid | DDocIdList]);
        not_found ->
            ok
    end,
    {noreply, St};

handle_cast(Msg, St) ->
    {stop, {invalid_cast, Msg}, St}.


handle_info({'EXIT', Pid, _Reason}, #st{evictor = Pid} = St) ->
    ?EVENT(evictor_died, Pid),
    {ok, Evictor} = couch_event:link_listener(
            ?MODULE, handle_db_event, nil, [all_dbs]
        ),
    {noreply, St#st{evictor=Evictor}};

handle_info(Msg, St) ->
    {stop, {invalid_info, Msg}, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.


handle_db_event(ShardDbName, created, St) ->
    gen_server:cast(?MODULE, {evict, mem3:dbname(ShardDbName)}),
    {ok, St};

handle_db_event(ShardDbName, deleted, St) ->
    gen_server:cast(?MODULE, {evict, mem3:dbname(ShardDbName)}),
    {ok, St};

handle_db_event(_DbName, _Event, St) ->
    {ok, St}.


store_key(Dbs, Key) ->
    DbName = ddoc_cache_entry:dbname(Key),
    DDocId = ddoc_cache_entry:ddocid(Key),
    case khash:lookup(Dbs, DbName) of
        {value, DDocIds} ->
            case khash:lookup(DDocIds, DDocId) of
                {value, Keys} ->
                    khash:put(Keys, Key, []);
                not_found ->
                    {ok, Keys} = khash:from_list([{Key, []}]),
                    khash:put(DDocIds, DDocId, Keys)
            end;
        not_found ->
            {ok, Keys} = khash:from_list([{Key, []}]),
            {ok, DDocIds} = khash:from_list([{DDocId, Keys}]),
            khash:put(Dbs, DbName, DDocIds)
    end.


remove_key(St, Key) ->
    #st{
        atimes = ATimes
    } = St,
    {value, ATime} = khash:lookup(ATimes, Key),
    remove_key(St, Key, ATime).


remove_key(St, Key, ATime) ->
    #st{
        atimes = ATimes
    } = St,
    true = ets:delete(?CACHE, Key),
    true = ets:delete(?LRU, ATime),
    ok = khash:del(ATimes, Key).


trim(St) ->
    #st{
        atimes = ATimes
    } = St,
    MaxSize = max(0, config:get_integer("ddoc_cache", "max_size", 1000)),
    case khash:size(ATimes) > MaxSize of
        true ->
            [{ATime, Key}] = ets:lookup(?LRU, ets:first(?LRU)),
            remove_key(St, Key, ATime),
            trim(St);
        false ->
            ok
    end.
