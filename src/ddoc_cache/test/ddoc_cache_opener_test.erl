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

-module(ddoc_cache_opener_test).


-include_lib("couch/include/couch_db.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("ddoc_cache_test.hrl").

%%
%% opener_test_() ->
%%     {
%%         setup,
%%         fun ddoc_cache_tutil:start_couch/0,
%%         fun ddoc_cache_tutil:stop_couch/1,
%%         {with, [
%%             fun check_multiple/1,
%%             fun handles_opened/1,
%%             fun handles_error/1
%%         ]}
%%     }.
%%
%%
%% check_multiple({DbName, _}) ->
%%     ddoc_cache_tutil:clear(),
%%     % We're faking multiple concurrent readers by pausing the
%%     % ddoc_cache_opener process, sending it a few messages
%%     % and then resuming the process.
%%     Pid = whereis(ddoc_cache_opener),
%%     Key = {ddoc_cache_entry_ddocid, {DbName, ?FOOBAR}},
%%     erlang:suspend_process(Pid),
%%     lists:foreach(fun(_) ->
%%         Pid ! {'$gen_call', {self(), make_ref()}, {open, Key}}
%%     end, lists:seq(1, 10)),
%%     erlang:resume_process(Pid),
%%     lists:foreach(fun(_) ->
%%         receive
%%             {_, {open_ok, _, _}} -> ok
%%         end
%%     end, lists:seq(1, 10)).
%%
%%
%% handles_opened({DbName, _}) ->
%%     ddoc_cache_tutil:clear(),
%%     {ok, _} = ddoc_cache:open_doc(DbName, ?FOOBAR),
%%     [#entry{key = Key, val = Val}] = ets:tab2list(?CACHE),
%%     Resp = gen_server:call(ddoc_cache_opener, {open, Key}),
%%     ?assertEqual({ok, Val}, Resp).
%%
%%
%% handles_error({DbName, _}) ->
%%     ddoc_cache_tutil:clear(),
%%     meck:new(ddoc_cache_entry, [passthrough]),
%%     meck:expect(ddoc_cache_entry, do_open, fun(_, _) ->
%%         couch_log:error("OHAI", []),
%%         erlang:error(borkity)
%%     end),
%%     try
%%         ?assertError(
%%                 {ddoc_cache_error, _},
%%                 ddoc_cache:open_doc(DbName, ?FOOBAR)
%%             )
%%     after
%%         meck:unload()
%%     end.
%%
