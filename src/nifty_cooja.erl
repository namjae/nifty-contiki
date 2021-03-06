%%% -------------------------------------------------------------------
%%% Copyright (c) 2014, Andreas Löscher <andreas.loscher@it.uu.se> and
%%%                     Konstantinos Sagonas <kostis@it.uu.se>
%%% All rights reserved.
%%%
%%% This file is distributed under the Simplified BSD License.
%%% Details can be found in the LICENSE file.
%%% -------------------------------------------------------------------

-module(nifty_cooja).
-export([%% cooja
	 start/2,
	 start/3,
	 state/0,
	 update_handler/1,
	 exit/0,
	 quit_cooja/1,
	 %% simulation
	 start_simulation/1,
	 stop_simulation/1,
	 is_running/1,
	 set_speed_limit/2,
	 set_random_seed/2,
	 simulation_time/1,
	 simulation_time_ms/1,
	 simulation_step_ms/1,
	 simulation_step/2,
	 simulation_step/3,
	 %% radio
	 radio_set_config/2,
	 radio_get_config/1,
	 radio_listen/2,
	 radio_unlisten/1,
	 radio_get_messages/1,
	 radio_no_dublicates/1,
	 radio_no_airshots/1,
	 %% motes
	 mote_types/1,
	 mote_add/2,
	 mote_new_id/3,
	 mote_del/2,
	 mote_get_pos/2,
	 mote_set_pos/3,
	 mote_get_clock/2,
	 mote_set_clock/3,
	 motes/1,
	 mote_write/3,
	 mote_listen/2,
	 mote_unlisten/2,
	 mote_hw_listen/2,
	 mote_hw_unlisten/2,
	 mote_hw_events/2,
	 mote_read/2,
	 mote_read_s/2,
	 mote_mem_vars/2,
	 mote_mem_symbol/3,
	 mote_mem_read/3,
	 mote_mem_write/4,
	 msg_wait/2,
	 get_last_event/2,
	 %% nifty interface
	 alloc/3,
	 alloc/4,
	 free/3,
	 write/3,
	 write/4,
	 read/4,
	 %% higher level
	 wait_for_result/2,
	 wait_for_result/3,
	 wait_for_msg/3,
	 wait_for_msg/4,
	 next_event/2,
	 next_event/3,
	 next_event_long/3,
	 next_event_long/4,
	 duty_cycle/2
	]).

-define(STEP_SIZE, 100).
-define(TIMEOUT, 60000).

start_node() ->
    [] = os:cmd("epmd -daemon"),
    case net_kernel:start([cooja_master, shortnames]) of
	{ok, _} ->
	    ok;
	{error, {already_started, _}} ->
	    ok
    end,
    case lists:member(cooja_master, registered()) of
	true ->
	    fail;
	false ->
	    register(cooja_master, self()),
	    ok
    end.

start(CoojaPath, Simfile) ->
    start(CoojaPath, Simfile, []).

start(RawCoojaPath, RawSimfile, Options) ->
    CoojaPath = nifty_utils:expand(RawCoojaPath),
    Simfile = nifty_utils:expand(RawSimfile),
    {ok, OldPath} = file:get_cwd(),
    Return = case start_node() of
		 ok ->
		     case lists:member(cooja_server, registered()) of
			 true -> 
			     fail;
			 false ->
			     CmdTmpl = case lists:member(gui, Options) of
					   true ->
					       "java -jar ~s -quickstart=~s";
					   _ ->
					       "java -jar ~s -nogui=~s"
				       end,
			     AbsSimPath = filename:absname(Simfile),
			     Cmd = format(CmdTmpl, ["cooja.jar", AbsSimPath]),
			     P = spawn(fun () -> start_command(CoojaPath, Cmd, lists:member(debug, Options)) 
				       end),
			     true = register(cooja_server, P),
			     receive
				 {pid, Pid} ->
				     Handler = case lists:member(record, Options) of
						   true ->
						       RecorderProcess = nifty_cooja_recorder:start_recorder(),
						       {Pid, [{timeout, ?TIMEOUT},
							      {step_size, ?STEP_SIZE},
							      {record, RecorderProcess}]};
						   _ ->
						       {Pid, [{timeout, ?TIMEOUT},
							      {step_size, ?STEP_SIZE}]}
					       end,
				     P ! {handler, Handler},
				     Handler
			     end
		     end;
		 fail ->
		     fail
	     end,
    ok = file:set_cwd(OldPath),
    Return.

wait_for_cooja() ->
    case state() of
	{running, _} ->
	    timer:sleep(100),
	    wait_for_cooja();
	Exit ->
	    Exit
    end.

exit() ->
    case state() of
	{running, Handler} ->
	    ok = quit_cooja(Handler),
	    nifty_cooja_recorder:stop_recorder(Handler),
	    wait_for_cooja();
	E ->
	    E
    end.

update_handler(Handler) ->
    case lists:member(cooja_server, registered()) of
	true ->
	    P = whereis(cooja_server),
	    P ! {handler, Handler},
	    nifty_cooja:state();
	false ->
	    not_running
    end.

state() ->
    case lists:member(cooja_server, registered()) of
	true ->
	    P = whereis(cooja_server),
	    P ! {state, self()},
	    receive
		{finished, {0, _}} -> ok;
		{finished, {R, O}} -> {error, {R, O}};
		{running, Handler} -> {running, Handler}
	    after
		1000 -> {error, {crash, cooja_server}}
	    end;
	false->
	    not_running
    end.

start_command(CoojaPath, Cmd, Debug) ->
    P = spawn(fun () ->command_fun(CoojaPath, Cmd, Debug) end),
    P ! {handler, self()},
    Handler = receive
		  {handler, H} -> H
	      end,
    handle_requests(Handler).

handle_requests(Handler) ->
    receive
	{result, {R, O}} ->
	    receive
		{state, P} ->
		    P ! {finished, {R, O}}
	    end;
	{state, P} ->
	    P ! {running, Handler},
	    handle_requests(Handler);
	{handler, NewHandler} ->
	    handle_requests(NewHandler)
    end.

command_fun(CoojaPath, Cmd, PrintOutput) ->
    S = receive
	    {handler, P} -> P
	end,
    {ok, OldPath} = file:get_cwd(),
    ok = file:set_cwd(filename:join([CoojaPath, "dist"])),
    {R, O} = command(Cmd),
    ok = case PrintOutput orelse not(R=:=0) of
	     true -> io:format("~s~n", [lists:flatten(O)]);
	     false -> ok
	 end,
    ok = file:set_cwd(OldPath),
    true = case lists:member(cooja_master, registered()) of
	       true ->
		   unregister(cooja_master);
	       _ ->
		   true
	   end,
    case PrintOutput of
	true ->
	    S ! {result, {R, O}};
	false ->
	    S ! {result, {R, "set debug option to see the output"}}
    end.

format(Format, Args) ->
    lists:flatten(io_lib:format(Format, Args)).

%% Taken form EUnit
%% ---------------------------------------------------------------------
%% Replacement for os:cmd

%% TODO: Better cmd support, especially on Windows (not much tested)
%% TODO: Can we capture stderr separately somehow?

command(Cmd) ->
    command(Cmd, "").

command(Cmd, Dir) ->
    command(Cmd, Dir, []).

command(Cmd, Dir, Env) ->
    CD = if Dir =:= "" -> [];
	    true -> [{cd, Dir}]
	 end,
    SetEnv = if Env =:= [] -> []; 
		true -> [{env, Env}]
	     end,
    Opt = CD ++ SetEnv ++ [stream, exit_status, use_stdio,
			   stderr_to_stdout, in, eof],
    P = open_port({spawn, Cmd}, Opt),
    get_data(P, []).

get_data(P, D) ->
    receive
	{P, {data, D1}} ->
	    get_data(P, [D1|D]);
	{P, eof} ->
	    port_close(P),    
	    receive
		{P, {exit_status, N}} ->
		    {N, normalize(lists:flatten(lists:reverse(D)))}
	    end
    end.

normalize([$\r, $\n | Cs]) ->
    [$\n | normalize(Cs)];
normalize([$\r | Cs]) ->
    [$\n | normalize(Cs)];
normalize([C | Cs]) ->
    [C | normalize(Cs)];
normalize([]) ->
    [].

%% ---------------------------------------------------------------------
%% Commands

receive_answer(Handler) ->
    receive_answer(Handler, 3600000).

receive_answer(_, T) when T=<0 -> 
    R = exit(),
    throw({crash, R});
receive_answer({_, Opts} = Handler, T) ->
    receive
	{Time, R} -> 
	    ok = case proplists:get_value(record, Opts) of
		     undefined ->
			 ok;
		     _ ->
			 nifty_cooja_recorder:record_event(Handler, {answer, Time, R})
		 end,
	    R
    after
	1000 -> 
	    case state() of
		{running, _} -> 
		    receive_answer(Handler, T-1000);
		E -> 
		    throw({not_running, E})
	    end
    end.

send_msg({P, Opts} = Handler, Msg) ->
    ok = case proplists:get_value(record, Opts) of
	     undefined ->
		 ok;
	     _ ->
		 nifty_cooja_recorder:record_event(Handler, {call, Msg})
	 end,
    P ! Msg.

quit_cooja(Handler) ->
    send_msg(Handler,{self(), quit_cooja}),
    receive_answer(Handler).

start_simulation(Handler) ->
    send_msg(Handler, {self(), start_simulation}),
    receive_answer(Handler).

stop_simulation(Handler) ->
    send_msg(Handler, {self(), stop_simulation}),
    receive_answer(Handler).

set_speed_limit(Handler, SpeedLimit) ->
    send_msg(Handler, {self(), set_speed_limit, {SpeedLimit}}),
    receive_answer(Handler).

set_random_seed(Handler, Seed) ->
    send_msg(Handler, {self(), set_random_seed, {Seed}}),
    receive_answer(Handler).

is_running(Handler) ->
    send_msg(Handler, {self(), is_running}),
    receive_answer(Handler).

simulation_time(Handler) ->
    send_msg(Handler, {self(), simulation_time}),
    receive_answer(Handler).

simulation_time_ms(Handler) ->
    send_msg(Handler, {self(), simulation_time_ms}),
    receive_answer(Handler).

simulation_step_ms(Handler) ->
    send_msg(Handler, {self(), simulation_step_ms}),
    receive_answer(Handler).

simulation_step(Handler, Time) ->
    send_msg(Handler, {self(), simulation_step, {Time}}),
    receive_answer(Handler).

simulation_step(Handler, Time, Timeout) ->
    {P, Opts} = Handler,
    NH = {P, [{timeout, Timeout} | proplists:delete(timeout, Opts)]},
    simulation_step(NH, Time).

radio_set_config(Handler, {Radio, Options}) ->
    send_msg(Handler, {self(), radio_set_config, {Radio, Options}}),
    receive_answer(Handler).

radio_get_config(Handler) ->
    send_msg(Handler, {self(), radio_get_config}),
    receive_answer(Handler).

radio_listen(Handler, Analyzers) ->
    send_msg(Handler, {self(), radio_listen, {Analyzers}}),
    receive_answer(Handler).
    
radio_unlisten(Handler) ->
    send_msg(Handler, {self(), radio_unlisten}),
    receive_answer(Handler).
    
radio_get_messages(Handler) ->
    send_msg(Handler, {self(), radio_get_messages}),
    receive_answer(Handler).

motes(Handler) ->
    send_msg(Handler, {self(), motes}),
    receive_answer(Handler).

mote_types(Handler) ->
    send_msg(Handler, {self(), mote_types}),
    receive_answer(Handler).

mote_add(Handler, Type) ->
    send_msg(Handler, {self(), mote_add, {Type}}),
    receive_answer(Handler).

mote_new_id(Handler, OldId, NewId) ->
    send_msg(Handler, {self(), mote_new_id, {OldId, NewId}}),
    receive_answer(Handler).

mote_del(Handler, Id) ->
    send_msg(Handler, {self(), mote_del, {Id}}),
    receive_answer(Handler).

mote_get_pos(Handler, Id) ->
    send_msg(Handler, {self(), mote_get_pos, {Id}}),
    receive_answer(Handler).

mote_set_pos(Handler, Id, Pos) ->
    {X, Y, Z} = Pos,
    send_msg(Handler, {self(), mote_set_pos, {Id, X, Y, Z}}),
    receive_answer(Handler).

mote_get_clock(Handler, Id) ->
    send_msg(Handler, {self(), mote_get_clock, {Id}}),
    receive_answer(Handler).

mote_set_clock(Handler, Id, ClockOptions) ->    
    send_msg(Handler, {self(), mote_set_clock, {Id, ClockOptions}}),
    receive_answer(Handler).

mote_write(Handler, Mote, Data) ->
    send_msg(Handler, {self(), mote_write, {Mote, Data}}),
    receive_answer(Handler).

mote_listen(Handler, Mote) ->
    send_msg(Handler, {self(), mote_listen, {Mote}}),
    receive_answer(Handler).

mote_unlisten(Handler, Mote) ->
    send_msg(Handler, {self(), mote_unliste, {Mote}}),
    receive_answer(Handler).

mote_hw_listen(Handler, Mote) ->
    send_msg(Handler, {self(), mote_hw_listen, {Mote}}),
    receive_answer(Handler).

mote_hw_unlisten(Handler, Mote) ->
    send_msg(Handler, {self(), mote_hw_unliste, {Mote}}),
    receive_answer(Handler).

mote_hw_events(Handler, Mote) ->
    send_msg(Handler, {self(), mote_hw_events, {Mote}}),
    receive_answer(Handler).

mote_read(Handler, Mote) ->
    send_msg(Handler, {self(), mote_read, {Mote}}),
    receive_answer(Handler).

mote_read_s(Handler, Mote) ->
    send_msg(Handler, {self(), mote_read_s, {Mote}}),
    receive_answer(Handler).

mote_mem_vars(Handler, Mote) ->
    send_msg(Handler, {self(), mote_mem_vars, {Mote}}),
    receive_answer(Handler).

mote_mem_symbol(Handler, Mote, SymbolName) ->
    send_msg(Handler, {self(), mote_mem_symbol, {Mote, SymbolName}}),
    receive_answer(Handler).

mote_mem_read(Handler, Mote, Symbol) ->
    send_msg(Handler, {self(), mote_mem_read, {Mote, Symbol}}),
    receive_answer(Handler).

mote_mem_write(Handler, Mote, Symbol, Data) ->
    send_msg(Handler, {self(), mote_mem_write, {Mote, Symbol, Data}}),
    receive_answer(Handler).

msg_wait(Handler, Msg) ->
    send_msg(Handler, {self(), msg_wait, {Msg}}),
    receive_answer(Handler).

get_last_event(Handler, Id) ->
    send_msg(Handler, {self(), get_last_event, {Id}}),
    case  receive_answer(Handler) of
	{not_running, E} -> {not_running, E};
	no_event -> no_event;
	R -> string:substr(R, 7, length(R)-7)
    end.

handler_step_size({_, Opts}) ->
    {_, V} = proplists:lookup(step_size, Opts),
    V.

handler_timeout({_, Opts}) ->
    {_, V} = proplists:lookup(timeout, Opts),
    V.

%% high-level stuff
radio_no_dublicates(Msg) ->
     radio_no_dublicates(Msg, []).

radio_no_dublicates([], Acc) -> 
    lists:reverse(Acc);
radio_no_dublicates([M|T], []) ->
    radio_no_dublicates(T, [M]);
radio_no_dublicates([M={Src1, Dst1, Ch1, Cnt1}|T], Acc = [{Src2, Dst2, Ch2, Cnt2}|AccTail]) ->
    case Cnt1=:=Cnt2 andalso Src1=:=Src2 andalso Ch1=:=Ch2 of
	true ->
	    NewDst = lists:usort(Dst1++Dst2),
	    radio_no_dublicates(T, [{Src1, NewDst, Ch1, Cnt1}|AccTail]);
	false ->
	    radio_no_dublicates(T, [M|Acc])
    end.

radio_no_airshots(Msg) ->
    lists:filter(fun ({_, D, _, _}) ->
			 D=/=[] end, Msg).

next_event(Handler, Mote) ->
    next_event(Handler, Mote, handler_timeout(Handler)).

next_event(_, _, T) when T=<0 -> throw(timeout);
next_event(Handler, Mote, T) ->
    StepSize = handler_step_size(Handler),
    case get_last_event(Handler, Mote) of
	not_listened_to ->
	    fail;
	badid ->
	    badid;
	no_event ->
	    ok = simulation_step(Handler, StepSize),
	    next_event(Handler, Mote, T-StepSize);
	E ->
	    E
    end.

next_event_long(Handler, Mote, T) ->
    next_event_long(Handler, Mote, T, T div 10).

next_event_long(_, _, T, _) when T=<0 -> throw(timeout);
next_event_long(Handler, Mote, T, S) ->
    case get_last_event(Handler, Mote) of
	not_listened_to ->
	    fail;
	badid ->
	    badid;
	no_event ->
	    ok = simulation_step(Handler, S),
	    next_event_long(Handler, Mote, T-S, S);
	E ->
	    E
    end.

wait_for_result(Handler, Mote) ->
    wait_for_result(Handler, Mote, handler_timeout(Handler)).

wait_for_result(_,_,T) when T=<0 -> throw(timeout);
wait_for_result(Handler, Mote, T) ->
    StepSize = handler_step_size(Handler),
    case state() of
	{running, _} ->
	    case mote_read(Handler, Mote) of
		"" ->
		    ok = simulation_step(Handler, StepSize),
		    wait_for_result(Handler, Mote, T-StepSize);
		S ->
		    case re:run(S, "DEBUG[^\n]*\n") of
			{match, [{_,_}]} ->
			    ok = simulation_step(Handler, StepSize),
			    %% io:format("<<~p>>~n", [S]),
			    wait_for_result(Handler, Mote, T-StepSize);
			_ ->
			    S
		    end
	    end;
	_ ->
	    undef
    end.

wait_for_msg(Handler, Mote, Msg) ->
    wait_for_msg(Handler, Mote, handler_timeout(Handler), Msg).

wait_for_msg(_, _, T, _) when T=<0 -> throw(timeout);
wait_for_msg(Handler, Mote, T, Msg) ->
    StepSize = handler_step_size(Handler),
    case state() of
	{running, _} ->
	    case mote_read(Handler, Mote) of
		"" ->
		    ok = simulation_step(Handler, StepSize),
		    wait_for_msg(Handler, Mote, T-StepSize, Msg);
		S ->
		    case re:run(S, "DEBUG[^\n]*\n") of
			{match, [{_,_}]} ->
			    ok = simulation_step(Handler, StepSize),
			    %% io:format("<<~p>>~n", [S]),
			    wait_for_msg(Handler, Mote, T-StepSize, Msg);
			_ ->
			    case re:run(S, Msg) of
				{match, _} ->
				    true;
				nomatch ->
				    ok = simulation_step(Handler, StepSize),
				    wait_for_msg(Handler, Mote, T-StepSize, Msg)
			    end
		    end
	    end;
	_ ->
	    false
    end.

stop_cond(Handler) ->
    case is_running(Handler) of
	true ->
	    stop_simulation(Handler),
	    true;
	false ->
	    false
    end.

start_cond(Handler, St) ->
    case St of
	true ->
	    start_simulation(Handler);
	false ->
	    ok
    end.

%% nifty functions
alloc(Handler, Mote, Size) ->
    alloc(Handler, Mote, Size, 1000).

alloc(Handler, Mote, Size, Wait) ->
    St = stop_cond(Handler),
    Command = format("-2 ~.b~n",[Size]),
    mote_write(Handler, Mote, Command),
    Result = case Wait of 
		 0 ->
		     ok;
		 T ->
		     R = wait_for_result(Handler, Mote, T),
		     %% 0x1234\n -> cut of first two and last character
		     %% io:format("Alloc result: <<~p>> from command: <<~p>>", [R, Command]),
		     list_to_integer(string:substr(R, 3, length(R)-3), 16)
	     end,
    ok = start_cond(Handler, St),
    Result.

free(Handler, Mote, Size) ->
    free(Handler, Mote, Size, 1000).

free(Handler, Mote, Size, Wait) ->
    St = stop_cond(Handler),
    Command = format("-5 ~.16b~n",[Size]),
    mote_write(Handler, Mote, Command),
    Result = case Wait of 
		 0 ->
		     ok;
		 T ->
		     true = wait_for_msg(Handler, Mote, T, "ok\n"),
		     ok
	     end,
    ok = start_cond(Handler, St),
    Result.

write(Handler, Mote, Data) ->
    Ptr = alloc(Handler, Mote, length(Data)),
    ok = write(Handler, Mote, Ptr, Data),
    Ptr.

write(Handler, Mote, Ptr, Data) ->
    St = stop_cond(Handler),
    Result = write_chunks(Handler, Mote, Data, Ptr, 20),
    ok = start_cond(Handler, St),
    Result.

write_chunks(_, _, [], _, _) -> ok;
write_chunks(Handler, Mote, Data, Ptr, ChS) -> 
    ToWrite = lists:sublist(Data, ChS),
    Rest = lists:nthtail(length(ToWrite), Data),
    CommandData = lists:flatten([format("~2.16.0b", [X]) || X<-ToWrite]),
    Command = format("-1 ~.16b ~s~n", [Ptr, CommandData]),
    mote_write(Handler, Mote, Command),
    case wait_for_result(Handler, Mote)=:="ok\n" of
    	true ->
    	    write_chunks(Handler, Mote, Rest, Ptr+length(ToWrite), ChS);
    	_ ->
    	    undef
    end.

read(Handler, Mote, Ptr, Size) ->
    St = stop_cond(Handler),
    Result = read_chunks(Handler, Mote, Ptr, Size, 20),
    ok = start_cond(Handler, St),
    Result.

read_chunks(Handler, Mote, Ptr, Size, ChS) ->
    read_chunks(Handler, Mote, Ptr, Size, ChS, []).

read_chunks(_, _, _, 0, _, Data) -> Data;
read_chunks(Handler, Mote, Ptr, Size, ChS, Acc) -> 
    ReadSize = case Size<ChS of
		   true ->
		       Size;
		   _ ->
		       ChS
	       end,
    Command = format("-3 ~.16b ~.b~n", [Ptr, ReadSize]),
    mote_write(Handler, Mote, Command),
    case wait_for_result(Handler, Mote) of
	undef ->
	    undef;
	RawData ->
	    read_chunks(Handler, Mote, Ptr+ReadSize, Size-ReadSize, ChS, Acc ++ pairs(lists:droplast(RawData)))
    end.

pairs(L) ->
    [list_to_integer(I, 16) ||I <-string:tokens(L, ",")].

duty_cycle(Events, SimTime) ->
    on_time(Events, 0, off, SimTime) / SimTime.

on_time([], Acc, off, _) -> Acc;
on_time([], Acc, Start, End) ->
    Acc + End - Start;
on_time([{Time,{radio, on}}|T], Acc, off, E) -> 
    on_time(T, Acc, Time, E);
on_time([{_,{radio, off}}|T], Acc, off, E) -> 
    on_time(T, Acc, off, E);
on_time([{Time,{radio, off}}|T], Acc, Start, E) -> 
    on_time(T, Acc + Time - Start, off, E);
on_time([_|T], Acc, S, E) -> 
    on_time(T, Acc, S, E).
