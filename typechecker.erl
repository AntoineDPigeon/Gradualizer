-module(typechecker).

-compile([export_all]).

compatible({type, _, any, []}, _) ->
  true;
compatible(_, {type, _, any, []}) ->
  true;
compatible({type, _, 'fun', Args1, Res1},{type, _, 'fun', Args2, Res2}) ->
    compatible_lists(Args1, Args2) andalso
	compatible(Res1, Res2);
compatible({type, _, tuple, Tys1}, {type, _, tuple, Tys2}) ->
    compatible_lists(Tys1, Tys2);
compatible({user_type, _, Name1, Args1}, {user_type, _, Name2, Args2}) ->
    Name1 =:= Name2 andalso
	compatible_lists(Args1, Args2);
compatible(_, _) ->
    false.



compatible_lists(TyList1,TyList2) ->
    length(TyList1) =:= length(TyList2) andalso
	lists:all(fun ({Ty1, Ty2}) ->
			  compatible(Ty1, Ty2)
		  end
		 ,lists:zip(TyList1, TyList2)).

% Arguments: An environment for functions, an environment for variables
% and the expression to type check.
% Returns the type of the expression and a collection of variables bound in
% the expression together with their type.
-spec type_check_expr(#{ any() => any() },#{ any() => any() }, any()) ->
			     { any(), #{ any() => any()} }.
type_check_expr(_FEnv, VEnv, {var, _, Var}) ->
    return(maps:get(Var, VEnv));
type_check_expr(FEnv, VEnv, {tuple, _, TS}) ->
    { Tys, VarBinds } = lists:unzip([ type_check_expr(FEnv, VEnv, Expr)
				    || Expr <- TS ]),
    { {type, 0, tuple, Tys}, union_var_binds(VarBinds) };
type_check_expr(FEnv, VEnv, {call, _, Name, Args}) ->
    { ArgTys, VarBinds} =
	lists:unzip([ type_check_expr(FEnv, VEnv, Arg) || Arg <- Args]),
    VarBind = union_var_binds(VarBinds),
    case type_check_fun(FEnv, VEnv, Name) of
	{type, _, any, []} ->
	    { {type, 0, any, []}, VarBind };
	{type, _, 'fun', [{type, _, product, TyArgs}, ResTy]} ->
	    case compatible_lists(TyArgs, ArgTys) of
		true ->
		    {ResTy, VarBind};
		false ->
		    throw(type_error)
	    end
    end;
type_check_expr(FEnv, VEnv, {block, _, Block}) ->
    type_check_block(FEnv, VEnv, Block);
type_check_expr(_FEnv, _VEnv, {string, _, _}) ->
    return({usertype, 0, string, []});
type_check_expr(_FEnv, _VEnv, {nil, _}) ->
    return({type, 0, nil, []});
type_check_expr(FEnv, VEnv, {'fun', _, {clauses, Clauses}}) ->
    infer_clauses(FEnv, VEnv, Clauses).


type_check_expr_in(FEnv, VEnv, {type, _, any, []}, Expr) ->
    type_check_expr(FEnv, VEnv, Expr);
type_check_expr_in(_FEnv, VEnv, Ty, {var, LINE, Var}) ->
    VarTy = maps:get(Var, VEnv),
    case compatible(VarTy, Ty) of
	true ->
	    return(VarTy);
	false ->
	    throw({type_error, tyVar, LINE})
    end;
type_check_expr_in(FEnv, VEnv, {type, _, tuple, Tys}, {tuple, _LINE, TS}) ->
    {ResTys, VarBinds} =
	lists:unzip(
	  lists:map(fun ({Ty, Expr}) -> type_check_expr_in(FEnv, VEnv, Ty, Expr)
		    end,
		    lists:zip(Tys,TS))),
    {{type, 0, tuple, ResTys}, VarBinds};
type_check_expr_in(FEnv, VEnv, ResTy, {'case', _, Expr, Clauses}) ->
    {ExprTy, VarBinds} = type_check_expr(FEnv, VEnv, Expr),
    VEnv2 = add_var_binds(VEnv, VarBinds),
    check_clauses(FEnv, VEnv2, ExprTy, ResTy, Clauses);
type_check_expr_in(FEnv, VEnv, ResTy, {call, _, Name, Args}) ->
    case type_check_fun(FEnv, VEnv, Name) of
	{type, _, any, []} ->
	    {_, VarBinds} =
		lists:unzip([ type_check_expr(FEnv, VEnv, Arg) || Arg <- Args]),
	        
	    VarBind = union_var_binds(VarBinds),
	    { {type, 0, any, []}, VarBind };
	{type, _, 'fun', [{type, _, product, TyArgs}, FunResTy]} ->
	    {_, VarBinds} =
		lists:unzip([ type_check_expr_in(FEnv, VEnv, TyArg, Arg)
			      || {TyArg, Arg} <- lists:zip(TyArgs, Args) ]),
	    case compatible(ResTy, FunResTy) of
		true ->
		    VarBind = union_var_binds(VarBinds),
		    {ResTy, VarBind};
		_ ->
		    throw(type_error)
	    end
    end.


type_check_fun(FEnv, _VEnv, {atom, _, Name}) ->
    maps:get(Name, FEnv);
type_check_fun(FEnv, _VEnv, {remote, _, {atom,_,Module}, {atom,_,Fun}}) ->
    maps:get({Module,Fun}, FEnv);
type_check_fun(FEnv, VEnv, Expr) ->
    type_check_expr(FEnv, VEnv, Expr).

type_check_block(FEnv, VEnv, [Expr]) ->
    type_check_expr(FEnv, VEnv, Expr);
type_check_block(FEnv, VEnv, [Expr | Exprs]) ->
    {_, VarBinds} = type_check_expr(FEnv, VEnv, Expr),
    type_check_block(FEnv, add_var_binds(VEnv, VarBinds), Exprs).

type_check_block_in(FEnv, VEnv, ResTy, [Expr]) ->
    type_check_expr_in(FEnv, VEnv, ResTy, Expr);
type_check_block_in(FEnv, VEnv, ResTy, [Expr | Exprs]) ->
    {_, VarBinds} = type_check_expr(FEnv, VEnv, Expr),
    type_check_block_in(FEnv, add_var_binds(VEnv, VarBinds), ResTy, Exprs).


infer_clauses(FEnv, VEnv, Clauses) ->
    {Tys, _VarBinds} =
	lists:unzip(lists:map(fun (Clause) ->
				  infer_clause(FEnv, VEnv, Clause)
			  end, Clauses)),
    merge_types(Tys).

infer_clause(FEnv, VEnv, {clause, _, Args, [], Block}) -> % We don't accept guards right now.
    VEnvNew = add_any_types_pats(Args, VEnv),
    type_check_block(FEnv, VEnvNew, Block).

% TODO: This function needs an extra argument; a type which is the result
% type of the clauses.
check_clauses(FEnv, VEnv, ArgsTy, ResTy, Clauses) ->
    {Tys, _VarBinds} =
	lists:unzip(lists:map(fun (Clause) ->
				  check_clause(FEnv, VEnv, ArgsTy, ResTy, Clause)
			  end, Clauses)),
    merge_types(Tys).

check_clause(FEnv, VEnv, ArgsTy, ResTy, {clause, _, Args, [], Block}) ->
    case length(ArgsTy) =:= length(Args) of
	false ->
	    throw(argument_length_mismatch);
	true ->
	    VEnvNew = add_types_pats(Args, ArgsTy, VEnv),
	    type_check_block_in(FEnv, VEnvNew, ResTy, Block)
    end.


type_check_function(FEnv, {function,_, Name, _NArgs, Clauses}) ->
    case maps:find(Name, FEnv) of
	{ok, {type, _, 'fun', [{type, _, product, ArgsTy}, ResTy]}} ->
	    Ty = check_clauses(FEnv, #{}, ArgsTy, ResTy, Clauses),
	    case compatible(Ty, ResTy) of
		true -> ResTy;
		false -> throw({result_type_mismatch, Ty, ResTy})
	    end;
	error ->
	    infer_clauses(FEnv, #{}, Clauses)
    end.

type_check_file(File) ->
    {ok, Forms} = epp:parse_file(File,[]),
    {Specs, Funs} = collect_specs_and_functions(Forms),
    FEnv = create_fenv(Specs),
    lists:map(fun (Function) ->
		      type_check_function(FEnv, Function) end, Funs).

collect_specs_and_functions(Forms) ->
    aux(Forms,[],[]).
aux([], Specs, Funs) ->
    {Specs, Funs};
aux([Fun={function, _, _, _, _} | Forms], Specs, Funs) ->
    aux(Forms, Specs, [Fun | Funs]);
aux([{attribute, _, spec, Spec} | Forms], Specs, Funs) ->
    aux(Forms, [Spec | Specs], Funs);
aux([_|Forms], Specs, Funs) ->
    aux(Forms, Specs, Funs).

merge_types([Ty]) ->
    Ty;
merge_types(apa) ->
    {apa,bepa}.

create_fenv([{{Name,_},[Type]}|Specs]) ->
    (create_fenv(Specs))#{ Name => Type };
create_fenv([{{Name,_},_}|_]) ->
    throw({multiple_types_not_supported,Name});
create_fenv([]) ->
    #{}.

add_types_pats([], [], VEnv) ->
    VEnv;
add_types_pats([Pat | Pats], [Ty | Tys], VEnv) ->
    add_types_pats(Pats, Tys, add_type_pat(Pat, Ty, VEnv)).

add_type_pat({var, _, '_'}, _Ty, VEnv) ->
    VEnv;
add_type_pat({var, _, A}, Ty, VEnv) ->
    VEnv#{ A => Ty };
add_type_pat({tuple, _, Pats}, {type, _, tuple, Tys}, VEnv) ->
    add_type_pat_list(Pats, Tys, VEnv).

add_type_pat_list([Pat|Pats], [Ty|Tys], VEnv) ->
    VEnv2 = add_type_pat(Pat, Ty, VEnv),
    add_type_pat_list(Pats, Tys, VEnv2);
add_type_pat_list([], [], VEnv) ->
    VEnv.


add_any_types_pats([], VEnv) ->
    VEnv;
add_any_types_pats([Pat|Pats], VEnv) ->
    add_any_types_pats(Pats, add_any_types_pat(Pat, VEnv)).

add_any_types_pat(A, VEnv) when is_atom(A) ->
    VEnv;
add_any_types_pat({match, _, P1, P2}, VEnv) ->
    add_any_types_pats([P1, P2], VEnv);
add_any_types_pat({cons, _, Head, Tail}, VEnv) ->
    add_any_types_pats([Head, Tail], VEnv);
add_any_types_pat({nil, _}, VEnv) ->
    VEnv;
add_any_types_pat({tuple, _, Pats}, VEnv) ->
    add_any_types_pats(Pats, VEnv);
add_any_types_pat({var, _,'_'}, VEnv) ->
    VEnv;
add_any_types_pat({var, _,A}, VEnv) ->
    VEnv#{ A => {type, 0, any, []} }.

%%% Helper functions

return(X) ->
    { X, #{} }.

union_var_binds([]) ->
    #{};
union_var_binds([ VarBind | VarBinds ]) ->
    merge(fun glb_types/2, VarBind, union_var_binds(VarBinds)).

add_var_binds(VEnv, VarBinds) ->
    merge(fun glb_types/2, VEnv, VarBinds).

merge(F, M1, M2) ->
    maps:fold(fun (K, V1, M) ->
		 maps:update_with(K, fun (V2) -> F(K, V1, V2) end, V1, M)
	 end, M2, M1).

% TODO: improve
% Is this the right function to use or should I always just return any()?
glb_types({type, _, N, Args1}, {type, _, N, Args2}) ->
    Args = [ glb_types(Arg1, Arg2) || {Arg1, Arg2} <- lists:zip(Args1, Args2) ],
    {type, 0, N, Args};
glb_types(_, _) ->
    {type, 0, any, []}.