%%This file is licensed under the terms of the Modified BSD License.
-module(future).
-export([start/6,start_for_rest/4]).
-export([get_after_await/2,get_blocking/3,await/3,poll/1,die/2,value_available/6]).
-export([task_started/3]).
-export([get_for_rest/1]).
-export([maybe_register_waiting_task/3,confirm_wait_unblocked/3]).
-include_lib("abs_types.hrl").
%%Future starts AsyncCallTask
%%and stores result

-behaviour(gc).
-export([get_references/1]).

-behaviour(gen_statem).
%%gen_statem callbacks
-export([init/1, callback_mode/0,
         running/3,      % task is running
         completing/3, % task is completed, waiting for caller cog(s) to acknowledge
         completed/3,   % task is gone, handling poll, .get and eventual gc
         code_change/4,terminate/3]).

-record(data, {calleetask,
               calleecog,
               references=[],
               value=none,
               waiting_tasks=[],
               cookie=none,
               register_in_gc=true,
               caller=none,
               event=undefined
              }).

%% Interacting with a future caller-side

start(null,_Method,_Params, _Info, _Cog, _Stack) ->
    throw(dataNullPointerException);
start(Callee,Method,Params, Info, Cog, Stack) ->
    %% Create the schedule event based on the invocation event; this is because
    %% we don't have access to the caller id from the callee.
    #event{caller_id=Cid, local_id=Lid, name=Name} = cog:register_invocation(Cog, Method),
    ScheduleEvent = #event{type=schedule, caller_id=Cid, local_id=Lid, name=Name},
    NewInfo = Info#task_info{event=ScheduleEvent},
    {ok, Ref} = gen_statem:start(?MODULE,[Callee,Method,Params,NewInfo,true,self()], []),
    wait_for_future_start(Ref, Cog, Stack),
    Ref.

wait_for_future_start(Ref, Cog, Stack) ->
    receive
        {started, _Ref} ->
            ok;
        {stop_world, _Sender} ->
            cog:task_is_blocked_for_gc(Cog, self(), get(task_info), get(this)),
            cog:task_is_runnable(Cog, self()),
            task:wait_for_token(Cog, [Ref | Stack]),
            wait_for_future_start(Ref, Cog, Stack);
        {get_references, Sender} ->
            cog:submit_references(Sender, gc:extract_references([Ref | Stack])),
            wait_for_future_start(Ref, Cog, Stack)
    end.


start_for_rest(Callee, Method, Params, Info) ->
    ScheduleEvent = #event{type=schedule, caller_id=modelapi, local_id={Method, Params}, name=Method},
    NewInfo = Info#task_info{event=ScheduleEvent},
    {ok, Ref} = gen_statem:start(?MODULE,[Callee,Method,Params,NewInfo,false,none], []),
    Ref.

get_after_await(null, _Cog) ->
    throw(dataNullPointerException);
get_after_await(Future, Cog)->
    case gen_statem:call(Future, {get, Cog}) of
        {ok,Value}->
            Value;
        {error,Reason}->
            exit(Reason)
    end.


poll(null) ->
    throw(dataNullPointerException);
poll(Future) ->
    case gen_statem:call(Future, poll) of
        completed -> true;
        unresolved -> false
    end.


get_blocking(null, _Cog, _Stack) ->
    throw(dataNullPointerException);
get_blocking(Future, Cog, Stack) ->
    case poll(Future) of
        true ->
            get_after_await(Future, Cog);
        false ->
            cog:block_cog_for_future(Cog, Future, Stack),
            task:wait_for_token(Cog, [Future | Stack]),
            get_after_await(Future, Cog)
    end.

await(null, _Cog, _Stack) ->
    throw(dataNullPointerException);
await(Future, Cog, Stack) ->
    cog:suspend_current_task_for_future(Cog, Future, Stack),
    gen_statem:call(Future, {done_waiting, Cog}).

get_for_rest(Future) ->
    register_waiting_process(Future, self()),
    receive {value_present, Future} -> ok end,
    confirm_wait_unblocked(Future, self()),
    Result=case gen_statem:call(Future, {get, modelapi}) of
               %% Explicitly re-export internal representation since it's
               %% deconstructed by modelapi_v2:handle_object_call
               {ok,Value}->
                   {ok, Value};
               {error,Reason}->
                   {error, Reason}
           end,
    Result.


%% replies with "unresolved" and arranges to call `cog:task_is_runnable/2'
%% when the future is completed, or replies with "completed".  In the latter
%% case, does not call task_is_runnable.
maybe_register_waiting_task(Future, _Cog=#cog{ref=CogRef}, Task) ->
    gen_statem:call(Future, {waiting, {CogRef, Task}});
maybe_register_waiting_task(Future, CogRef, Task) ->
    gen_statem:call(Future, {waiting, {CogRef, Task}}).

register_waiting_process(Future, Pid) ->
    gen_statem:call(Future, {waiting, Pid}).

confirm_wait_unblocked(Future, #cog{ref=CogRef}, TaskRef) ->
    gen_statem:cast(Future, {okthx, {CogRef, TaskRef}});
confirm_wait_unblocked(Future, CogRef, TaskRef) ->
    gen_statem:cast(Future, {okthx, {CogRef, TaskRef}}).
confirm_wait_unblocked(Future, Pid) ->
    gen_statem:cast(Future, {okthx, Pid}).


%% Interacting with a future callee-side

value_available(Future, Status, Value, Sender, Cog, Cookie) ->
    %% will send back Cookie to Sender
    gen_statem:cast(Future, {completed, Status, Value, Sender, Cog, Cookie}).

task_started(Future, TaskRef, _Cookie) ->
    gen_statem:cast(Future, {task_ready, TaskRef}).


%% Interacting with a future from gc

get_references(Future) ->
    gen_statem:call(Future, get_references).

die(Future, Reason) ->
    gen_statem:cast(Future, {die, Reason}).


notify_completion({CogRef, TaskRef}) ->
    cog:task_is_runnable(CogRef, TaskRef);
notify_completion(Pid) ->
    Pid ! {value_present, self()}.


%% gen_statem machinery

callback_mode() -> state_functions.

init([Callee=#object{oid=Object,cog=Cog=#cog{ref=CogRef}},Method,Params,Info,RegisterInGC,Caller]) ->
    %%Start task
    process_flag(trap_exit, true),
    %% We used to wrap the following line in a
    %% erlang:monitor(process, CogRef) / erlang:demonitor()
    %% call, but if Object is alive, so is (presumably)
    %% CogRef, and Object cannot have been garbage-collected
    %% in the meantime.
    TaskRef=cog:add_task(Cog,async_call_task,self(),Callee,[Method|Params], Info#task_info{this=Callee,destiny=self()}, Params),
    case RegisterInGC of
        true -> gc:register_future(self());
        false -> ok
    end,
    case Caller of
        none -> ok;
        _ -> Caller ! {started, self()} % in cooperation with start/3
    end,
    {ok, running, #data{calleetask=TaskRef,
                        calleecog=Cog,
                        references=gc:extract_references(Params),
                        value=none,
                        waiting_tasks=[],
                        register_in_gc=RegisterInGC,
                        caller=Caller,
                        event=Info#task_info.event}};
init([_Callee=null,_Method,_Params,RegisterInGC,Caller]) ->
    %% This is dead code, left in for reference; a `null' callee is caught in
    %% future:start above.
    case Caller of
        none -> ok;
        _ -> Caller ! {started, self()}
    end,
    {ok, completed, #data{value={error, dataNullPointerException},
                          calleecog=none,
                          calleetask=none,
                          register_in_gc=RegisterInGC}}.



handle_info({'EXIT',_Pid,Reason}, running, Data=#data{register_in_gc=RegisterInGC, waiting_tasks=WaitingTasks}) ->
    lists:map(fun notify_completion/1, WaitingTasks),
    case RegisterInGC of
        true -> gc:unroot_future(self());
        false -> ok
    end,
    {next_state, completed, Data#data{value={error,error_transform:transform(Reason)}}};
handle_info(_Info, StateName, Data) ->
    {next_state, StateName, Data}.

terminate(_Reason, completed, _Data) ->
    ok;
terminate(Reason, StateName, Data) ->
    error_logger:format("Future ~w got unexpected terminate with reason ~w in state ~w/~w~n", [self(), Reason, StateName, Data]).

code_change(_OldVsn, StateName, Data, _Extra) ->
    {ok, StateName, Data}.


handle_call(From, poll, Data=#data{value=Value}) ->
    case Value of
        none -> {keep_state_and_data, {reply, From, unresolved}};
        _ -> {keep_state_and_data, {reply, From, completed}}
    end;
handle_call(_From, _Event, Data) ->
    {stop, not_supported, Data}.



%% State functions

next_state_on_completion(Data=#data{waiting_tasks=[], calleetask=TerminatingProcess, cookie=Cookie, register_in_gc=RegisterInGC}) ->
    TerminatingProcess ! {Cookie, self()},
    case RegisterInGC of
        true -> gc:unroot_future(self());
        false -> ok
    end,
    {completed, Data};
next_state_on_completion(Data=#data{waiting_tasks=WaitingTasks}) ->
    lists:map(fun notify_completion/1, WaitingTasks),
    {completing, Data}.


running({call, From}, get_references, Data=#data{references=References}) ->
    {keep_state, Data, {reply, From, References}};
running({call, From}, {waiting, Task}, Data=#data{waiting_tasks=WaitingTasks}) ->
    {keep_state, Data#data{waiting_tasks=[Task | WaitingTasks]},
     {reply, From, unresolved}};
running(cast, {completed, value, Result, Sender, SenderCog, Cookie},
        Data=#data{calleetask=Sender,calleecog=SenderCog})->
    {NextState, Data1} = next_state_on_completion(Data#data{cookie=Cookie}),
    {next_state, NextState, Data1#data{value={ok,Result}, references=[]}};
running(cast, {completed, exception, Result, Sender, SenderCog, Cookie},
        Data=#data{calleetask=Sender,calleecog=SenderCog})->
    {NextState, Data1} = next_state_on_completion(Data#data{cookie=Cookie}),
    {next_state, NextState, Data1#data{value={error,Result}, references=[]}};
running({call, From}, Msg, Data) ->
    handle_call(From, Msg, Data);
running(info, Msg, Data) ->
    handle_info(Msg, running, Data).


next_state_on_okthx(Data=#data{calleetask=CalleeTask,waiting_tasks=WaitingTasks, cookie=Cookie, register_in_gc=RegisterInGC}, Task) ->
    NewWaitingTasks=lists:delete(Task, WaitingTasks),
    case NewWaitingTasks of
        [] ->
            CalleeTask ! {Cookie, self()},
            case RegisterInGC of
                true -> gc:unroot_future(self());
                false -> ok
            end,
            {completed, Data#data{waiting_tasks=[]}};
        _ ->
            {completing, Data#data{waiting_tasks=NewWaitingTasks}}
    end.

completing({call, From}, get_references, _Data=#data{value=Value}) ->
    {keep_state_and_data, {reply, From, gc:extract_references(Value)}};
completing({call, From}, {done_waiting, Cog}, Data=#data{value=Value,event=Event}) ->
    #event{caller_id=Cid, local_id=Lid, name=Name, reads=R, writes=W} = Event,
    CompletionEvent=#event{type=await_future, caller_id=Cid,
                           local_id=Lid, name=Name, reads=R, writes=W},
    cog:register_await_future_complete(Cog, CompletionEvent),
    {keep_state_and_data, {reply, From, Value}};
completing({call, From}, {get, modelapi}, _Data=#data{value=Value,event=Event}) ->
    {keep_state_and_data, {reply, From, Value}};
completing({call, From}, {get, Cog}, _Data=#data{value=Value,event=Event}) ->
    #event{caller_id=Cid, local_id=Lid, name=Name, reads=R, writes=W} = Event,
    CompletionEvent=#event{type=future_read, caller_id=Cid,
                           local_id=Lid, name=Name, reads=R, writes=W},
    cog:register_future_read(Cog, CompletionEvent),
    {keep_state_and_data, {reply, From, Value}};
completing(cast, {okthx, Task}, Data) ->
    {NextState, Data1} = next_state_on_okthx(Data, Task),
    {next_state, NextState, Data1};
completing({call, From}, {waiting, Task}, Data=#data{waiting_tasks=WaitingTasks}) ->
    {keep_state, Data#data{waiting_tasks=[Task | WaitingTasks]},
     {reply, From, completed}};
completing({call, From}, Msg, Data) ->
    handle_call(From, Msg, Data);
completing(info, Msg, Data) ->
    handle_info(Msg, completing, Data).


completed({call, From}, get_references, _Data=#data{value=Value}) ->
    {keep_state_and_data, {reply, From, gc:extract_references(Value)}};
completed({call, From}, {done_waiting, Cog}, Data=#data{value=Value,event=Event}) ->
    #event{caller_id=Cid, local_id=Lid, name=Name, reads=R, writes=W} = Event,
    CompletionEvent=#event{type=await_future, caller_id=Cid,
                           local_id=Lid, name=Name, reads=R, writes=W},
    cog:register_await_future_complete(Cog, CompletionEvent),
    {keep_state_and_data, {reply, From, Value}};
completed({call, From}, {get, modelapi}, _Data=#data{value=Value,event=Event}) ->
    {keep_state_and_data, {reply, From, Value}};
completed({call, From}, {get, Cog}, _Data=#data{value=Value,event=Event}) ->
    #event{caller_id=Cid, local_id=Lid, name=Name, reads=R, writes=W} = Event,
    CompletionEvent=#event{type=future_read, caller_id=Cid,
                           local_id=Lid, name=Name, reads=R, writes=W},
    cog:register_future_read(Cog, CompletionEvent),
    {keep_state_and_data, {reply, From, Value}};
completed(cast, {die, _Reason}, Data) ->
    {stop, normal, Data};
completed(cast, {okthx, _Task}, _Data) ->
    keep_state_and_data;
completed({call, From}, {waiting, _Task}, _Data) ->
    {keep_state_and_data, {reply, From, completed}};
completed({call, From}, Msg, Data) ->
    handle_call(From, Msg, Data);
completed(info, Msg, Data) ->
    handle_info(Msg, completed, Data).
