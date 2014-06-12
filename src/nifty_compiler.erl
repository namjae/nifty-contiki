-module(nifty_compiler).
-export([render/4,
	 compile/3]).

-type reason() :: atom().
-type options() :: proplists:proplist().
-type renderout() :: iolist().
-type modulename() :: string().

%% @doc Renders an <code>InterfaceFile</code> into a Erlang module containing of <code>ModuleName</code>.erl
%% <code>ModuleName</code>.c, <code>ModuleName</code>.app and  <code>rebar</code>.config and returns the 
%% contents of these files as tuple of iolists (in this order). It uses <code>CFlags</code> to parse the
%% <code>InterfaceFile</code> and <code>Options</code> to compile it. <code>Options</code> are equivalent to
%% rebar options.
-spec render(string(), modulename(), [string()], options()) -> {error,reason()} | renderout().
render(InterfaceFile, ModuleName, CFlags, Options) ->
    io:format("generating ~s -> ~s ~s ~n", [InterfaceFile, ModuleName++"_nif.c", ModuleName++".erl"]),
    %% c parse stuff
    PathToH = InterfaceFile,
    case nifty_clangparse:parse([PathToH|CFlags]) of
	{fail, _} -> 
	    {error, compile};
	{{[],[]}, _} ->
	    {error, empty};
	{{Token, FuncLoc}, _} -> 
	    {Raw_Functions, Raw_Typedefs, Raw_Structs} = nifty_clangparse:build_vars(Token),
	    %% io:format("~p~n", [Functions]),
	    Unsave_Functions = filter_functions(InterfaceFile, Raw_Functions, FuncLoc),
	    {Unsave_Types, Symbols} = nifty_typetable:build({Raw_Functions, Raw_Typedefs, Raw_Structs}),
	    {_, Types} = nifty_typetable:check_types({Unsave_Functions, Raw_Typedefs, Raw_Structs}, Unsave_Types),
	    RenderVars = [{"module", ModuleName},
			  {"header", InterfaceFile},
			  {"config", Options},
			  {"types", Types},
			  {"symbols", Symbols},
			  {"maxbuf", "100"},
			  {"none", none}],
	    {ok, COutput} = nifty_contiki_template:render(RenderVars),
	    COutput
    end.

filter_functions(InterfaceFile, Functions, FuncLoc) ->
    filter_functions(filename:basename(InterfaceFile), dict:new(), Functions, FuncLoc).

filter_functions(_, New, _, []) ->
    New;
filter_functions(Ref, New, Old, [{Func, File}|T]) ->
    Updated_New = case Ref=:=filename:basename(File) of
		      true ->
			  case dict:is_key(Func, Old) of
			      true ->
				  dict:store(Func, dict:fetch(Func, Old), New);
			      false ->
				  New
			  end;
		      false ->
			  New
		  end,
    filter_functions(Ref, Updated_New, Old, T).

store_files(InterfaceFile, ModuleName, Options, RenderOutput) ->
    {ok, Path} = file:get_cwd(),
    store_files(InterfaceFile, ModuleName, Options, RenderOutput, Path).

store_files(_, ModuleName, _, RenderOutput, Path) ->
    ok = case file:make_dir(filename:join([Path,ModuleName])) of
	     ok -> ok;
	     {error,eexist} -> ok;
	     _ -> fail
	 end,
    ContikiOutput = RenderOutput,
    ok = fwrite_render(Path, ModuleName, ".", "contiki_app.c", ContikiOutput).

fwrite_render(Path, ModuleName, Dir, FileName, Template) ->
    file:write_file(filename:join([Path, ModuleName, Dir, FileName]), [Template]).

%% @doc Generates a NIF module out of a C header file and compiles it, 
%% generating wrapper functions for all functions present in the header file. 
%% <code>InterfaceFile</code> specifies the header file. <code>Module</code> specifies 
%% the module name of the translated NIF. <code>Options</code> specifies the compile
%% options. These options are equivalent to rebar's config options.
-spec compile(string(), module(), options()) -> 'ok' | 'fail'.
compile(InterfaceFile, Module, Options) ->
    ModuleName = atom_to_list(Module),
    os:putenv("NIF", libname(ModuleName)),
    {ok, NiftyRoot} = file:get_cwd(),
    os:putenv("NIFTY_ROOT", NiftyRoot),
    UCO = update_compile_options(InterfaceFile, ModuleName, Options),
    Env = build_env(ModuleName, UCO),
    CFlags = string:tokens(proplists:get_value("CFLAGS", Env, ""), " "),
    case render(InterfaceFile, ModuleName, CFlags, UCO) of
	{error, E} -> 
	    {error, E};
	Output ->
	    ok = store_files(InterfaceFile, ModuleName, UCO, Output)
    end.

build_env(ModuleName, Options) ->
    Env = case proplists:get_value(port_env, Options) of
	      undefined -> [];
	      EnvList -> EnvList
	  end,
    EnvAll = case proplists:get_value(port_specs, Options) of
		 undefined -> Env;
		 SpecList ->
		     lists:concat([Env, get_spec_env(ModuleName, SpecList)])
	     end,
    rebar_port_compiler:setup_env({config, undefined, [{port_env, EnvAll}], undefined, undefined, undefined, dict:new()}).

get_spec_env(_, []) -> [];
get_spec_env(ModuleName, [S|T]) ->
    Lib = libname(ModuleName),
    case S of
	{_, Lib, _, Options} ->
	    case proplists:get_value(env, Options) of
		undefined -> [];
		Env -> expand_env(Env, [])
	    end;
	_ ->
	    get_spec_env(ModuleName, T)
    end.

norm_opts(Options) ->
    case proplists:get_value(env, Options) of
	undefined -> Options;
	Env -> 
	    [{env, merge_env(expand_env(Env, []), dict:new())}| proplists:delete(env, Options)]
    end.

merge_env([], D) -> dict:to_list(D);
merge_env([{Key, Opt}|T], D) ->
    case dict:is_key(Key, D) of
	true ->
	    merge_env(T, dict:store(Key, dict:fetch(Key,D) ++ " " ++ remove_envvar(Key, Opt), D));
	false ->
	    merge_env(T, dict:store(Key, Opt, D))
    end.

remove_envvar(Key, Opt) -> 
    %% remove in the beginning and the end
    Striped = string:strip(Opt),
    K1 = "${" ++ Key ++ "}",
    K2 = "$" ++ Key,
    K3 = "%" ++ Key,
    E1 = length(Striped) - length(K1) + 1,
    E23 = length(Striped) - length(K2) + 1,
    case string:str(Striped, K1) of
	1 ->
	    string:substr(Striped, length(K1)+1);	   
	E1 ->
	    string:substr(Striped, 1, E1);
	_ ->
	    case string:str(Striped, K2) of
		1 ->
		    string:substr(Striped, length(K2)+1);
		E23 ->
		    string:substr(Striped, 1, E23 -1);
		_ ->
		    case string:str(Striped, K3) of
			1 ->
			    string:substr(Striped, length(K3)+1);	   
			E23 ->
			    string:substr(Striped, 1, E23 - 1);
			_ ->
			    Striped
		    end
	    end
    end.

expand_env([], Acc) ->
    Acc;
expand_env([{ON, O}|T], Acc) ->
    expand_env(T, [{ON, nifty_utils:expand(O)}|Acc]).

libname(ModuleName) ->
    "priv/"++ModuleName++"_nif.so".

update_compile_options(InterfaceFile, ModuleName, CompileOptions) ->
    NewPort_Spec = case proplists:get_value(port_specs, CompileOptions) of
		       undefined -> 
			   [module_spec(".*", [], [], InterfaceFile, ModuleName)];
		       UPortSpec ->	
			   update_port_spec(InterfaceFile, ModuleName, UPortSpec, [], false)
		   end,
    orddict:store(port_specs, NewPort_Spec, orddict:from_list(CompileOptions)).

module_spec(ARCH, Sources, Options, InterfaceFile,  ModuleName) ->
    {
      ARCH, 
      libname(ModuleName),
      ["c_src/"++ModuleName++"_nif.c"|abspath_sources(Sources)],
      norm_opts(join_options([{env, 
			       [{"CFLAGS", 
				 "$CFLAGS -I"++filename:absname(filename:dirname(nifty_utils:expand(InterfaceFile)))}]}], 
			     Options))
    }.

join_options(Proplist1, Proplist2) ->
    orddict:merge(
      fun(_,X,Y) -> X++Y end,
      orddict:from_list(Proplist1),
      orddict:from_list(Proplist2)).

abspath_sources(S) -> abspath_sources(S, []).

abspath_sources([], Acc) -> Acc;
abspath_sources([S|T], Acc) ->
    abspath_sources(T, [filename:absname(nifty_utils:expand(S))|Acc]).


update_port_spec(_,  _, [], Acc, true) -> 
    Acc;
update_port_spec(InterfaceFile,  ModuleName, [], Acc, false) -> %% empty spec
    [module_spec(".*", [], [], InterfaceFile, ModuleName), Acc];
update_port_spec(InterfaceFile,  ModuleName, [Spec|T], Acc, Found) ->
    Shared = libname(ModuleName),
    case expand_spec(Spec) of
	{ARCH, Shared, Sources} ->
	    update_port_spec(
	      InterfaceFile, 
	      ModuleName, 
	      T,  
	      [module_spec(ARCH, Sources, [], InterfaceFile, ModuleName)|Acc], true);
	{ARCH, Shared, Sources, Options} ->
	    update_port_spec(
	      InterfaceFile,
	      ModuleName,
	      T, 
	      [module_spec(ARCH, Sources, Options, InterfaceFile, ModuleName)|Acc], true);
	_ ->
	    update_port_spec(InterfaceFile, ModuleName, T, [Spec|Acc], Found)
    end.

expand_spec(S) ->
    case S of
	{ARCH, Shared, Sources} ->
	    {ARCH, nifty_utils:expand(Shared), norm_sources(Sources)};
	{ARCH, Shared, Sources, Options} ->
	    {ARCH, nifty_utils:expand(Shared), norm_sources(Sources), Options}
    end.

norm_sources(S) ->
    [nifty_utils:expand(X) || X <- S].
