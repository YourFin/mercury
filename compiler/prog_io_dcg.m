%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: prog_io_dcg.m.
% Main authors: fjh, zs.
%
% This module handles the parsing of clauses in Definite Clause Grammar
% notation.

:- module prog_io_dcg.

:- interface.

:- import_module prog_data, prog_io_util.
:- import_module list, varset, term, io.

:- pred parse_dcg_clause(string, varset, term, term, term__context,
			maybe_item_and_context).
:- mode parse_dcg_clause(in, in, in, in, in, out) is det.

:- implementation.

:- import_module prog_io_goal, prog_util.
:- import_module int, string, std_util, varset.

%-----------------------------------------------------------------------------%

parse_dcg_clause(ModuleName, VarSet0, DCG_Head, DCG_Body, DCG_Context,
		Result) :-
	new_dcg_var(VarSet0, 0, VarSet1, N0, DCG_0_Var),
	parse_dcg_goal(DCG_Body, VarSet1, N0, DCG_0_Var,
			Body, VarSet, _N, DCG_Var),
	parse_qualified_term(ModuleName, DCG_Head, "DCG clause head",
			HeadResult),
	process_dcg_clause(HeadResult, VarSet, DCG_0_Var, DCG_Var, Body, R),
	add_context(R, DCG_Context, Result).

%-----------------------------------------------------------------------------%

	% Used to allocate fresh variables needed for the DCG expansion.

:- pred new_dcg_var(varset, int, varset, int, var).
:- mode new_dcg_var(in, in, out, out, out) is det.

new_dcg_var(VarSet0, N0, VarSet, N, DCG_0_Var) :-
	string__int_to_string(N0, StringN),
	string__append("DCG_", StringN, VarName),
	varset__new_var(VarSet0, DCG_0_Var, VarSet1),
	varset__name_var(VarSet1, DCG_0_Var, VarName, VarSet),
	N is N0 + 1.

%-----------------------------------------------------------------------------%

	% Expand a DCG goal.

:- pred parse_dcg_goal(term, varset, int, var, goal, varset, int, var).
:- mode parse_dcg_goal(in, in, in, in, out, out, out, out) is det.

parse_dcg_goal(Term, VarSet0, N0, Var0, Goal, VarSet, N, Var) :-
	% first, figure out the context for the goal
	(
		Term = term__functor(_, _, Context)
	;
		Term = term__variable(_),
		term__context_init(Context)
	),
	% next, parse it
	(
		sym_name_and_args(Term, SymName, Args0)
	->
		% First check for the special cases:
		(
			SymName = unqualified(Functor),
			parse_dcg_goal_2(Functor, Args0, Context,
					VarSet0, N0, Var0,
					Goal1, VarSet1, N1, Var1)
		->
			Goal = Goal1,
			VarSet = VarSet1,
			N = N1,
			Var = Var1
		;
			% It's the ordinary case of non-terminal.
			% Create a fresh var as the DCG output var from this
			% goal, and append the DCG argument pair to the
			% non-terminal's argument list.
			new_dcg_var(VarSet0, N0, VarSet, N, Var),
			list__append(Args0,
				[term__variable(Var0), term__variable(Var)],
				Args),
			Goal = call(SymName, Args) - Context
		)
	;
		% A call to a free variable, or to a number or string.
		% Just translate it into a call to call/3 - the typechecker
		% will catch calls to numbers and strings.
		new_dcg_var(VarSet0, N0, VarSet, N, Var),
		Goal = call(unqualified("call"), [Term, term__variable(Var0),
				term__variable(Var)]) - Context
	).

	% parse_dcg_goal_2(Functor, Args, Context, VarSet0, N0, Var0,
	%			Goal, VarSet, N, Var):
	% VarSet0/VarSet are an accumulator pair which we use to
	% allocate fresh DCG variables; N0 and N are an accumulator pair
	% we use to keep track of the number to give to the next DCG
	% variable (so that we can give it a semi-meaningful name "DCG_<N>"
	% for use in error messages, debugging, etc.).
	% Var0 and Var are an accumulator pair we use to keep track of
	% the current DCG variable.

:- pred parse_dcg_goal_2(string, list(term), term__context, varset, int, var,
				goal, varset, int, var).
:- mode parse_dcg_goal_2(in, in, in, in, in, in, out, out, out, out)
				is semidet.

	% The following is a temporary and gross hack to strip out
	% calls to `io__gc_call', since the mode checker can't handle
	% them yet.
parse_dcg_goal_2("io__gc_call", [Goal0],
		_, VarSet0, N0, Var0, Goal, VarSet, N, Var) :-
	parse_dcg_goal(Goal0, VarSet0, N0, Var0, Goal, VarSet, N, Var).

	% Ordinary goal inside { curly braces }.
parse_dcg_goal_2("{}", [G], _, VarSet0, N, Var,
		Goal, VarSet, N, Var) :-
	parse_goal(G, VarSet0, Goal, VarSet).

	% Empty list - just unify the input and output DCG args.
parse_dcg_goal_2("[]", [], Context, VarSet0, N0, Var0,
		Goal, VarSet, N, Var) :-
	new_dcg_var(VarSet0, N0, VarSet, N, Var),
	Goal = unify(term__variable(Var0), term__variable(Var)) - Context.

	% Non-empty list of terminals.  Append the DCG output arg
	% as the new tail of the list, and unify the result with
	% the DCG input arg.
parse_dcg_goal_2(".", [X, Xs], Context, VarSet0, N0, Var0,
		Goal, VarSet, N, Var) :-
	new_dcg_var(VarSet0, N0, VarSet, N, Var),
	term_list_append_term(term__functor(term__atom("."), [X, Xs], Context),
			term__variable(Var), Term), 
	Goal = unify(term__variable(Var0), Term) - Context.

	% Call to '='/1 - unify argument with DCG input arg.
parse_dcg_goal_2("=", [A], Context, VarSet, N, Var,
		Goal, VarSet, N, Var) :-
	Goal = unify(A, term__variable(Var)) - Context.

	% If-then (Prolog syntax).
	% We need to add an else part to unify the DCG args.

/******
	Since (A -> B) has different semantics in standard Prolog
	(A -> B ; fail) than it does in NU-Prolog or Mercury (A -> B ; true),
	for the moment we'll just disallow it.
parse_dcg_goal_2("->", [Cond0, Then0], Context, VarSet0, N0, Var0,
		Goal, VarSet, N, Var) :-
	parse_dcg_if_then(Cond0, Then0, Context, VarSet0, N0, Var0,
		SomeVars, Cond, Then, VarSet, N, Var),
	( Var = Var0 ->
		Goal = if_then(SomeVars, Cond, Then) - Context
	;
		Unify = unify(term__variable(Var), term__variable(Var0)),
		Goal = if_then_else(SomeVars, Cond, Then, Unify - Context)
			- Context
	).
******/

	% If-then (NU-Prolog syntax).
parse_dcg_goal_2("if", [
			term__functor(term__atom("then"), [Cond0, Then0], _)
		], Context, VarSet0, N0, Var0, Goal, VarSet, N, Var) :-
	parse_dcg_if_then(Cond0, Then0, Context, VarSet0, N0, Var0,
		SomeVars, Cond, Then, VarSet, N, Var),
	( Var = Var0 ->
		Goal = if_then(SomeVars, Cond, Then) - Context
	;
		Unify = unify(term__variable(Var), term__variable(Var0)),
		Goal = if_then_else(SomeVars, Cond, Then, Unify - Context)
			- Context
	).

	% Conjunction.
parse_dcg_goal_2(",", [A0, B0], Context, VarSet0, N0, Var0,
		(A, B) - Context, VarSet, N, Var) :-
	parse_dcg_goal(A0, VarSet0, N0, Var0, A, VarSet1, N1, Var1),
	parse_dcg_goal(B0, VarSet1, N1, Var1, B, VarSet, N, Var).

	% Disjunction or if-then-else (Prolog syntax).
parse_dcg_goal_2(";", [A0, B0], Context, VarSet0, N0, Var0,
		Goal, VarSet, N, Var) :-
	(
		A0 = term__functor(term__atom("->"), [Cond0, Then0], _Context)
	->
		parse_dcg_if_then_else(Cond0, Then0, B0, Context,
			VarSet0, N0, Var0, Goal, VarSet, N, Var)
	;
		parse_dcg_goal(A0, VarSet0, N0, Var0, A1, VarSet1, N1, VarA),
		parse_dcg_goal(B0, VarSet1, N1, Var0, B1, VarSet, N, VarB),
		( VarA = Var0, VarB = Var0 ->
			Var = Var0,
			Goal = (A1 ; B1) - Context
		; VarA = Var0 ->
			Var = VarB,
			Unify = unify(term__variable(Var),
				term__variable(VarA)),
			append_to_disjunct(A1, Unify, Context, A2),
			Goal = (A2 ; B1) - Context
		; VarB = Var0 ->
			Var = VarA,
			Unify = unify(term__variable(Var),
				term__variable(VarB)),
			append_to_disjunct(B1, Unify, Context, B2),
			Goal = (A1 ; B2) - Context
		;
			Var = VarB,
			prog_util__rename_in_goal(A1, VarA, VarB, A2),
			Goal = (A2 ; B1) - Context
		)
	).

	% If-then-else (NU-Prolog syntax).
parse_dcg_goal_2( "else", [
		    term__functor(term__atom("if"), [
			term__functor(term__atom("then"), [Cond0, Then0], _)
		    ], Context),
		    Else0
		], _, VarSet0, N0, Var0, Goal, VarSet, N, Var) :-
	parse_dcg_if_then_else(Cond0, Then0, Else0, Context,
		VarSet0, N0, Var0, Goal, VarSet, N, Var).

	% Negation (NU-Prolog syntax).
parse_dcg_goal_2( "not", [A0], Context, VarSet0, N0, Var0,
		not(A) - Context, VarSet, N, Var ) :-
	parse_dcg_goal(A0, VarSet0, N0, Var0, A, VarSet, N, _),
	Var = Var0.

	% Negation (Prolog syntax).
parse_dcg_goal_2( "\\+", [A0], Context, VarSet0, N0, Var0,
		not(A) - Context, VarSet, N, Var ) :-
	parse_dcg_goal(A0, VarSet0, N0, Var0, A, VarSet, N, _),
	Var = Var0.

	% Universal quantification.
parse_dcg_goal_2("all", [Vars0, A0], Context,
		VarSet0, N0, Var0, all(Vars, A) - Context, VarSet, N, Var) :-
	term__vars(Vars0, Vars),
	parse_dcg_goal(A0, VarSet0, N0, Var0, A, VarSet, N, Var).

	% Existential quantification.
parse_dcg_goal_2("some", [Vars0, A0], Context,
		VarSet0, N0, Var0, some(Vars, A) - Context, VarSet, N, Var) :-
	term__vars(Vars0, Vars),
	parse_dcg_goal(A0, VarSet0, N0, Var0, A, VarSet, N, Var).

:- pred append_to_disjunct(goal, goal_expr, term__context, goal).
:- mode append_to_disjunct(in, in, in, out) is det.

append_to_disjunct(Disjunct0, Goal, Context, Disjunct) :-
	( Disjunct0 = (A0 ; B0) - Context2 ->
		append_to_disjunct(A0, Goal, Context, A),
		append_to_disjunct(B0, Goal, Context, B),
		Disjunct = (A ; B) - Context2
	;
		Disjunct = (Disjunct0, Goal - Context) - Context
	).

:- pred parse_some_vars_dcg_goal(term, vars, varset, int, var,
				goal, varset, int, var).
:- mode parse_some_vars_dcg_goal(in, out, in, in, in, out, out, out, out)
	is det.
parse_some_vars_dcg_goal(A0, SomeVars, VarSet0, N0, Var0, A, VarSet, N, Var) :-
	( A0 = term__functor(term__atom("some"), [SomeVars0, A1], _Context) ->
		term__vars(SomeVars0, SomeVars),
		A2 = A1
	;
		SomeVars = [],
		A2 = A0
	),
	parse_dcg_goal(A2, VarSet0, N0, Var0, A, VarSet, N, Var).

	% Parse the "if" and the "then" part of an if-then or an
	% if-then-else.
	% If the condition is a DCG goal, but then "then" part
	% is not, then we need to translate
	%	( a -> { b } ; c )
	% as
	%	( a(DCG_1, DCG_2) ->
	%		b,
	%		DCG_3 = DCG_2
	%	;
	%		c(DCG_1, DCG_3)
	%	)
	% rather than
	%	( a(DCG_1, DCG_2) ->
	%		b
	%	;
	%		c(DCG_1, DCG_2)
	%	)
	% so that the implicit quantification of DCG_2 is correct.

:- pred parse_dcg_if_then(term, term, term__context, varset, int, var,
		list(var), goal, goal, varset, int, var).
:- mode parse_dcg_if_then(in, in, in, in, in, in, out, out, out, out, out, out)
	is det.

parse_dcg_if_then(Cond0, Then0, Context, VarSet0, N0, Var0,
		SomeVars, Cond, Then, VarSet, N, Var) :-
	parse_some_vars_dcg_goal(Cond0, SomeVars, VarSet0, N0, Var0,
				Cond, VarSet1, N1, Var1),
	parse_dcg_goal(Then0, VarSet1, N1, Var1, Then1, VarSet2, N2, Var2),
	( Var0 \= Var1, Var1 = Var2 ->
		new_dcg_var(VarSet2, N2, VarSet, N, Var),
		Unify = unify(term__variable(Var), term__variable(Var2)),
		Then = (Then1, Unify - Context) - Context
	;
		Then = Then1,
		N = N2,
		Var = Var2,
		VarSet = VarSet2
	).

:- pred parse_dcg_if_then_else(term, term, term, term__context,
	varset, int, var, goal, varset, int, var).
:- mode parse_dcg_if_then_else(in, in, in, in, in, in, in,
	out, out, out, out) is det.

parse_dcg_if_then_else(Cond0, Then0, Else0, Context, VarSet0, N0, Var0,
		Goal, VarSet, N, Var) :-
	parse_dcg_if_then(Cond0, Then0, Context, VarSet0, N0, Var0,
		SomeVars, Cond, Then1, VarSet1, N1, VarThen),
	parse_dcg_goal(Else0, VarSet1, N1, Var0, Else1, VarSet, N, VarElse),
	( VarThen = Var0, VarElse = Var0 ->
		Var = Var0,
		Then = Then1,
		Else = Else1
	; VarThen = Var0 ->
		Var = VarElse,
		Unify = unify(term__variable(Var), term__variable(VarThen)),
		Then = (Then1, Unify - Context) - Context,
		Else = Else1
	; VarElse = Var0 ->
		Var = VarThen,
		Then = Then1,
		Unify = unify(term__variable(Var), term__variable(VarElse)),
		Else = (Else1, Unify - Context) - Context
	;
		% We prefer to substitute the then part since it is likely
		% to be smaller than the else part, since the else part may
		% have a deeply nested chain of if-then-elses.

		% parse_dcg_if_then guarantees that if VarThen \= Var0,
		% then the then part introduces a new DCG variable (i.e.
		% VarThen does not appear in the condition). We therefore
		% don't need to do the substitution in the condition.

		Var = VarElse,
		prog_util__rename_in_goal(Then1, VarThen, VarElse, Then),
		Else = Else1
	),
	Goal = if_then_else(SomeVars, Cond, Then, Else) - Context.

	% term_list_append_term(ListTerm, Term, Result):
	% 	if ListTerm is a term representing a proper list, 
	%	this predicate will append the term Term
	%	onto the end of the list

:- pred term_list_append_term(term, term, term).
:- mode term_list_append_term(in, in, out) is semidet.

term_list_append_term(List0, Term, List) :-
	( List0 = term__functor(term__atom("[]"), [], _Context) ->
		List = Term
	;
		List0 = term__functor(term__atom("."), [Head, Tail0], Context2),
		List = term__functor(term__atom("."), [Head, Tail], Context2),
		term_list_append_term(Tail0, Term, Tail)
	).

:- pred process_dcg_clause(maybe_functor, varset, var, var, goal, maybe1(item)).
:- mode process_dcg_clause(in, in, in, in, in, out) is det.

process_dcg_clause(ok(Name, Args0), VarSet, Var0, Var, Body,
		ok(pred_clause(VarSet, Name, Args, Body))) :-
	list__append(Args0, [term__variable(Var0), term__variable(Var)], Args).
process_dcg_clause(error(Message, Term), _, _, _, _, error(Message, Term)).
