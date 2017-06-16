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

-module(ddoc_cache_entry).


-export([
    spawn_opener/1,
    spawn_refresher/1,

    open/1,
    handle_resp/1,

    dbname/1,
    ddocid/1
]).

-export([
    do_open/2
]).


dbname({Mod, Arg}) ->
    Mod:dbname(Arg).


ddocid({Mod, Arg}) ->
    Mod:ddocid(Arg).


spawn_opener(Key) ->
    erlang:spawn_link(?MODULE, do_open, [Key, true]).


spawn_refresher(Key) ->
    erlang:spawn_monitor(?MODULE, do_open, [Key, false]).


handle_resp({open_ok, _Key, Resp}) ->
    Resp;

handle_resp({open_error, _Key, Type, Reason, Stack}) ->
    erlang:raise(Type, Reason, Stack);

handle_resp(Other) ->
    erlang:error({ddoc_cache_error, Other}).


open(Key) ->
    {_Pid, Ref} = erlang:spawn_monitor(?MODULE, do_open, [Key, false]),
    receive
        {'DOWN', Ref, _, _, Resp} ->
            handle_resp(Resp)
    end.


do_open({Mod, Arg} = Key, DoInsert) ->
    try Mod:recover(Arg) of
        {ok, Resp} when DoInsert ->
            ddoc_cache_lru:insert(Key, Resp),
            erlang:exit({open_ok, Key, {ok, Resp}});
        Resp ->
            erlang:exit({open_ok, Key, Resp})
    catch T:R ->
        S = erlang:get_stacktrace(),
        erlang:exit({open_error, Key, T, R, S})
    end.
