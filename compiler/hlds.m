%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

% HLDS - The High-Level Data Structure.

% Main authors: fjh, conway, zs.

% This file contains the data types for the high-level data structure.
% The file is arranged as follows: first all the data structures are
% listed.  Most of these are private to this module, with access
% predicates provided.  Those that are not are explicitly exported
% using a `:- export_type' directive.
% Then for each data structure, we give the interface and then
% the implementation for the access predicates for that data structure.
%
% Although most of the data structures are private, it is a quite thin
% layer of abstraction.
%
% WARNING: changes here will probably require changes in make_hlds.nl
% and elsewhere.

:- module hlds.
:- interface.
:- import_module int, string, list, set, varset, term, map, prog_io.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- type module_info	--->	module(
					string,		% module name
					pred_table,
					list(pred_id),
					pred_name_index,
					type_table,
					inst_table,
					mode_table,
					cons_table,
					int,		% number of errors
					int		% number of warnings
				).

%-----------------------------------------------------------------------------%

	% The symbol table for predicates.

:- type pred_info	
	--->	predicate(
			varset,		% names of _type_ vars
					% in the pred type decl
			list(type),	% argument types
			condition,	% formal specification
					% (not used)

			clauses_info,

			proc_table,

			term__context,	% the location (line #)
					% of the :- pred decl.

			bool		% unused junk
		).

:- type clauses_info	--->	clauses_info(
					varset,		% variable names
					map(var, type), % variable types
					list(var),	% head vars
					list(clause)
				).

:- type clause		--->	clause(
					list(proc_id),  % modes for which
							% this clause applies
					hlds__goal,	% Body
					term__context
				).

%%% :- export_type proc_table.
:- type proc_table	==	map(proc_id, proc_info).

:- type proc_info	--->	procedure(
					determinism,	% _declared_ determism
					varset,		% variable names
					map(var, type),	% variable types
					list(var),	% head vars
					list(mode), 	% modes of args
					hlds__goal,	% Body
					term__context,	% The context of
							% the :- mode decl,
							% not the clause.	
					call_info,	% stack allocations
					category,	% _inferred_ det'ism
					list(arg_info)	% information about
							% the arguments
							% derived from the
							% modes etc
				).

%%% :- export_type category.
:- type category	--->	deterministic		% functional & total
			;	semideterministic	% just functional
			;	nondeterministic.	% neither

%%% :- export_type det_source.
:- type det_source	--->	declared
			;	inferred.

:- type pred_id 	--->	pred(module_name, string, int).
			%	module, predname, arity

%%% :- export_type pred_table.
:- type pred_table	==	map(pred_id, pred_info).

%%% :- export_type pred_name_index.
:- type pred_name_index	==	map(string, list(pred_id)).

:- type procedure_id	--->	proc(pred_id, proc_id).

	% a proc_id is a mode number within a particular predicate -
	% not to be confused with a mode_id, which is the name of a
	% user-defined mode.
:- type proc_id		==	int.

%-----------------------------------------------------------------------------%

	% The symbol table for types.

:- type type_id		== 	pair(sym_name, int).
				% name, arity

%%% :- export_type type_table.
:- type type_table	==	map(type_id, hlds__type_defn).

%-----------------------------------------------------------------------------%

	% The symbol table for modes.

:- type mode_id		==	pair(sym_name, int).
				% name, arity

%%% :- export_type mode_table.
:- type mode_table	==	map(mode_id, hlds__mode_defn).

:- type mode_info	==	map(var, mode).

%-----------------------------------------------------------------------------%

	% The symbol table for insts.

:- type inst_id		==	pair(sym_name, int).
				% name, arity.

%%% :- export_type inst_table.
:- type inst_table	==	map(inst_id, hlds__inst_defn).

%-----------------------------------------------------------------------------%

	% The symbol table for constructors.
	% This table is used by the type-checker to look
	% up the type of functors/constants.

:- type cons_id		--->	cons(string, int)	% name, arity
			;	int_const(int)
			;	string_const(string)
			;	float_const(float).

%%% :- export_type cons_table.
:- type cons_table	==	map(cons_id, list(hlds__cons_defn)).

%-----------------------------------------------------------------------------%

:- type arg_info	--->	arginfo(
					arg_loc,	% stored location
					arg_mode	% mode of top functor
				).

:- type arg_mode	
	--->	top_in
	;	top_out
	;	top_unused.

:- type arg_loc == int.

%-----------------------------------------------------------------------------%

	% Here's how goals are represented

%%% :- export_type hlds__goal.
:- type hlds__goal		== pair(hlds__goal_expr, hlds__goal_info).

%%% :- export_type hlds__goal_expr.
:- type hlds__goal_expr    	--->	
				% A conjunction
				conj(hlds__goals)

				% Initially only the pred_id and arguments
				% are filled in.  Mode analysis fills in the
				% proc_id.  Just before code generation,
				% we do a pass over the hlds which recognizes
				% the builtins and fills in the is_builtin
				% field.
			;	call(pred_id, proc_id, list(term), is_builtin)

				% Deterministic disjunctions are converted
				% into case statements by the switch
				% detection pass.
				% Variable, functor-args-goal, followvars
			;	switch(var, list(case), follow_vars)

				% Initially only the terms and the context
				% are know.  Mode analysis fills in the
				% missing information.
			;	unify(term, term, unify_mode, unification,
								unify_context)
			;	disj(hlds__goals)
			;	not(list(var), hlds__goal)
			;	all(list(var), hlds__goal)
			;	some(list(var), hlds__goal)
			;	if_then_else(list(var), hlds__goal,
					hlds__goal, hlds__goal).

	% Record whether a call is a builtin or not, and if so, which one.
%%% :- export_type is_builtin.
:- type is_builtin	--->	not_builtin
			;	is_builtin.

%%% :- export_type call_info.
:- type call_info	==	map(var, int).

%%% :- export_type case.
:- type case		--->	case(cons_id, list(var), hlds__goal).
			%	functor to match with, arguments to extract,
			%	goal to execute if match succeeds.

	% Initially all unifications are represented as
	% unify(term, term, _, _), but mode analysis replaces
	% these with various special cases.

%%% :- export_type follow_vars.
:- type follow_vars	==	map(var, register_slot).
%%% :- export_type register_slot.
:- type register_slot		==	int.

%%% :- export_type unification.
:- type unification	--->	
				% Y = f(X) where the top node of Y is output,
				% written as Y := f(X).
				construct(var, cons_id, list(var), list(mode))

				% Y = f(X) where the top node of Y is input,
				% written Y == f(X).
			;	deconstruct(var, cons_id, list(var), list(mode))

				% Y = X where the top node of Y is output,
				% written Y := X.
			;	assign(var, var)

				% Y = X where the type of X and Y is an atomic
				% type and they are both input, written X == Y.
			;	simple_test(var, var)	

				% Y = X where the type of Y and X is not an
				% atomic type, and where the top-level node
				% of both Y and X is input.  May involve
				% bi-directional data flow.  Implemented
				% using out-of-line call to  a compiler
				% generated unification predicate for that
				% type & mode.
			;	complicated_unify(unify_mode, term, term).

:- type unify_context	--->	unify_context(
					unify_main_context,
					unify_sub_contexts
				).

:- type unify_main_context --->	explicit
			;	head(int)
			;	call(pred_id, int).

:- type unify_sub_context ==	pair(cons_id, int).

:- type unify_sub_contexts ==	list(unify_sub_context).

%%% :- export_type hlds__goals.
:- type hlds__goals		==	list(hlds__goal).

:- type hlds__goal_info
	---> goalinfo(
		map(var, is_live),	% XXX this is O(N*N)
		determinism,	% the declared determinism
				% (current always unspecified, since
				% there's no way to declare the determinism
				% of a goal.)
		category, 	% the inferred determinism
		instmap_delta,
		term__context,
		set(var)	% the non-local vars in the goal
	).

%%% :- export_type is_live.
:- type is_live		--->	live ; dead.

:- type unify_mode	==	pair(mode, mode).

%-----------------------------------------------------------------------------%

	% This is how type, modes and constructors are represented.
	% The parts that are not defined here (i.e. type_param, constructor,
	% type, inst, mode, condition) are represented in the same way as
	% in prog_io.nl, and are defined there.

:- type hlds__type_defn	--->	hlds__type_defn(
						% names of type vars (empty 
						% except for polymorphic types)
					varset,	
						% formal type parameters
					list(type_param),
						% the definition of the type
					hlds__type_body,
						% a class invariant for the
						% type (not used)
					condition,
					term__context
				).

	% du = discriminated union, uu = undiscriminated union,
	% eqv_type = equivalence type (a type defined to be eqv to some
	% other type)

:- type hlds__type_body	--->	du_type(list(constructor))
			;	uu_type(list(type))
			;	eqv_type(type)
			;	abstract_type.

:- type hlds__inst_defn --->	hlds__inst_defn(varset, list(inst_param),
					hlds__inst_body,
					condition, term__context).

:- type hlds__inst_body	--->	eqv_inst(inst)
			;	abstract_inst.

:- type hlds__mode_defn --->	hlds__mode_defn(varset, list(inst_param),
					hlds__mode_body,
					condition, term__context).

:- type hlds__mode_body --->	eqv_mode(mode).

:- type hlds__cons_defn	--->	hlds__cons_defn(
					%%% maybe: varset,
					list(type),	% arg types
					type_id,	% result type
					term__context
				).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% Various predicates for manipulating the module_info data structure

:- interface.

:- pred moduleinfo_init(string, module_info).
:- mode moduleinfo_init(input, output).

:- pred moduleinfo_name(module_info, string).
:- mode moduleinfo_name(input, output).

:- pred moduleinfo_preds(module_info, pred_table).
:- mode moduleinfo_preds(input, output).

:- pred moduleinfo_predids(module_info, list(pred_id)).
:- mode moduleinfo_predids(input, output).

:- pred moduleinfo_pred_name_index(module_info, pred_name_index).
:- mode moduleinfo_pred_name_index(input, output).

:- pred moduleinfo_types(module_info, type_table).
:- mode moduleinfo_types(input, output).

:- pred moduleinfo_typeids(module_info, list(type_id)).
:- mode moduleinfo_typeids(input, output).

:- pred moduleinfo_insts(module_info, inst_table).
:- mode moduleinfo_insts(input, output).

:- pred moduleinfo_instids(module_info, list(inst_id)).
:- mode moduleinfo_instids(input, output).

:- pred moduleinfo_modes(module_info, mode_table).
:- mode moduleinfo_modes(input, output).

:- pred moduleinfo_modeids(module_info, list(mode_id)).
:- mode moduleinfo_modeids(input, output).

:- pred moduleinfo_ctors(module_info, cons_table).
:- mode moduleinfo_ctors(input, output).

:- pred moduleinfo_num_errors(module_info, int).
:- mode moduleinfo_num_errors(input, output).

:- pred moduleinfo_num_warnings(module_info, int).
:- mode moduleinfo_num_warnings(input, output).

:- pred moduleinfo_consids(module_info, list(cons_id)).
:- mode moduleinfo_consids(input, output).

:- pred moduleinfo_set_name(module_info, string, module_info).
:- mode moduleinfo_set_name(input, input, output).

:- pred moduleinfo_set_preds(module_info, pred_table, module_info).
:- mode moduleinfo_set_preds(input, input, output).

:- pred moduleinfo_set_predids(module_info, list(pred_id), module_info).
:- mode moduleinfo_set_predids(input, input, output).

:- pred moduleinfo_set_pred_name_index(module_info, pred_name_index,
					module_info).
:- mode moduleinfo_set_pred_name_index(input, input, output).

:- pred moduleinfo_set_types(module_info, type_table, module_info).
:- mode moduleinfo_set_types(input, input, output).

:- pred moduleinfo_set_insts(module_info, inst_table, module_info).
:- mode moduleinfo_set_insts(input, input, output).

:- pred moduleinfo_set_modes(module_info, mode_table, module_info).
:- mode moduleinfo_set_modes(input, input, output).

:- pred moduleinfo_set_ctors(module_info, cons_table, module_info).
:- mode moduleinfo_set_ctors(input, input, output).

:- pred moduleinfo_set_num_errors(module_info, int, module_info).
:- mode moduleinfo_set_num_errors(input, input, output).

:- pred moduleinfo_incr_errors(module_info, module_info).
:- mode moduleinfo_incr_errors(input, output).

:- pred moduleinfo_incr_warnings(module_info, module_info).
:- mode moduleinfo_incr_warnings(input, output).

:- pred moduleinfo_remove_predid(module_info, pred_id, module_info).
:- mode moduleinfo_remove_predid(in, in, out) is det.

%-----------------------------------------------------------------------------%

:- implementation.

	% A predicate which creates an empty module

moduleinfo_init(Name, module(Name, Preds, [], PredNameIndex, Types, Insts,
		Modes, Ctors, 0, 0)) :-
	map__init(Preds),
	map__init(PredNameIndex),
	map__init(Types),
	map__init(Insts),
	map__init(Modes),
	map__init(Ctors).

	% Various access predicates which extract different pieces
	% of info from the module_info data structure.

moduleinfo_name(ModuleInfo, Name) :-
	ModuleInfo = module(Name, _, _, _, _, _, _, _, _, _).

moduleinfo_preds(ModuleInfo, Preds) :-
	ModuleInfo = module(_, Preds, _, _, _, _, _, _, _, _).

moduleinfo_predids(ModuleInfo, PredIDs) :-
	ModuleInfo = module(_, _, PredIDs, _, _, _, _, _, _, _).

moduleinfo_pred_name_index(ModuleInfo, PredNameIndex) :-
	ModuleInfo = module(_, _, _, PredNameIndex, _, _, _, _, _, _).

moduleinfo_types(ModuleInfo, Types) :-
	ModuleInfo = module(_, _, _, _, Types, _, _, _, _, _).

moduleinfo_typeids(ModuleInfo, TypeIDs) :-
	ModuleInfo = module(_, _, _, _, Types, _, _, _, _, _),
	map__keys(Types, TypeIDs).

moduleinfo_insts(ModuleInfo, Insts) :-
	ModuleInfo = module(_, _, _, _, _, Insts, _, _, _, _).

moduleinfo_instids(ModuleInfo, InstIDs) :-
	ModuleInfo = module(_, _, _, _, _, Insts, _, _, _, _),
	map__keys(Insts, InstIDs).

moduleinfo_modes(ModuleInfo, Modes) :-
	ModuleInfo = module(_, _, _, _, _, _, Modes, _, _, _).

moduleinfo_modeids(ModuleInfo, ModeIDs) :-
	ModuleInfo = module(_, _, _, _, _, _, Modes, _, _, _),
	map__keys(Modes, ModeIDs).

moduleinfo_ctors(ModuleInfo, Ctors) :-
	ModuleInfo = module(_, _, _, _, _, _, _, Ctors, _, _).

moduleinfo_consids(ModuleInfo, ConsIDs) :-
	ModuleInfo = module(_, _, _, _, _, _, _, Ctors, _, _),
	map__keys(Ctors, ConsIDs).

moduleinfo_num_errors(ModuleInfo, NumErrors) :-
	ModuleInfo = module(_, _, _, _, _, _, _, _, NumErrors, _).

moduleinfo_num_warnings(ModuleInfo, NumWarnings) :-
	ModuleInfo = module(_, _, _, _, _, _, _, _, _, NumWarnings).

	% Various predicates which modify the module_info data structure.

moduleinfo_set_name(ModuleInfo0, Name, ModuleInfo) :-
	ModuleInfo0 = module(_, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_preds(ModuleInfo0, Preds, ModuleInfo) :-
	ModuleInfo0 = module(Name, _, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_predids(ModuleInfo0, PredIDs, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, _, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_pred_name_index(ModuleInfo0, PredNameIndex, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, _, Types,
				Insts, Modes, Ctors, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_types(ModuleInfo0, Types, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, PredNameIndex, _,
				Insts, Modes, Ctors, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_insts(ModuleInfo0, Insts, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, PredNameIndex, Types,
				_, Modes, Ctors, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_modes(ModuleInfo0, Modes, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, _, Ctors, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_ctors(ModuleInfo0, Ctors, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, _, Errs, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_set_num_errors(ModuleInfo0, Errs, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, _, Warns),
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_incr_errors(ModuleInfo0, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs0, Warns),
	Errs is Errs0 + 1,
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_incr_warnings(ModuleInfo0, ModuleInfo) :-
	ModuleInfo0 = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns0),
	Warns0 is Warns + 1,
	ModuleInfo = module(Name, Preds, PredIDs, PredNameIndex, Types,
				Insts, Modes, Ctors, Errs, Warns).

moduleinfo_remove_predid(ModuleInfo0, PredId, ModuleInfo) :-
	moduleinfo_predids(ModuleInfo0, PredIds0),
	delete_all(PredIds0, PredId, PredIds),
	moduleinfo_set_predids(ModuleInfo0, PredIds, ModuleInfo).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% Various predicates for accessing the cons_id type.

:- interface.

:- pred make_functor_cons_id(const, int, cons_id).
:- mode make_functor_cons_id(in, in, out) is det.

:- pred make_cons_id(sym_name, list(type), type_id, cons_id).
:- mode make_cons_id(input, input, input, output) is det.

%-----------------------------------------------------------------------------%

:- implementation.

make_functor_cons_id(term_atom(Name), Arity, cons(Name, Arity)).
make_functor_cons_id(term_integer(Int), _, int_const(Int)).
make_functor_cons_id(term_string(String), _, string_const(String)).
make_functor_cons_id(term_float(Float), _, float_const(Float)).

make_cons_id(qualified(_Module, Name), Args, _TypeId, cons(Name, Arity)) :-
	length(Args, Arity).
make_cons_id(unqualified(Name), Args, _TypeId, cons(Name, Arity)) :-
	length(Args, Arity).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% Various predicates for accessing the information stored in the
	% pred_id and pred_info data structures.

:- interface.

:- pred predicate_module(pred_id, module_name).
:- mode predicate_module(input, output).

:- pred predicate_name(pred_id, string).
:- mode predicate_name(input, output).

:- pred predicate_arity(pred_id, int).
:- mode predicate_arity(input, output).

:- pred make_predid(string, sym_name, int, pred_id).
:- mode make_predid(input, input, input, output).


:- pred predinfo_proc_ids(pred_info, list(proc_id)).
:- mode predinfo_proc_ids(input, output).

:- pred predinfo_arg_types(pred_info, varset, list(type)).
:- mode predinfo_arg_types(input, output, output).

:- pred predinfo_clauses_info(pred_info, clauses_info).
:- mode predinfo_clauses_info(input, output).

:- pred predinfo_set_clauses_info(pred_info, clauses_info, pred_info).
:- mode predinfo_set_clauses_info(input, input, output).

:- pred predinfo_procedures(pred_info, proc_table).
:- mode predinfo_procedures(input, output).

:- pred predinfo_set_procedures(pred_info, proc_table, pred_info).
:- mode predinfo_set_procedures(input, input, output).

:- pred predinfo_procids(pred_info, list(proc_id)).
:- mode predinfo_procids(input, output).

:- pred predinfo_context(pred_info, term__context).
:- mode predinfo_context(input, output).

:- pred predinfo_is_imported(pred_info::in) is semidet.

%-----------------------------------------------------------------------------%

:- implementation.

predicate_module(pred(Module,_Name,_Arity), Module).

predicate_name(pred(_Module,Name,_Arity), Name).

predicate_arity(pred(_Module,_Name,Arity), Arity).

make_predid(ModName, unqualified(Name), Arity, pred(ModName, Name, Arity)).
make_predid(_, qualified(ModName, Name), Arity, pred(ModName, Name, Arity)).

predinfo_proc_ids(PredInfo, ProcIds) :-
	PredInfo = predicate(_, _, _, _, Procs, _, _),
	map__keys(Procs, ProcIds).

predinfo_clauses_info(PredInfo, Clauses) :-
	PredInfo = predicate(_, _, _, Clauses, _, _, _).

predinfo_set_clauses_info(PredInfo0, Clauses, PredInfo) :-
	PredInfo0 = predicate(TypeVars, ArgTypes, Cond, _, Procs, C, Err),
	PredInfo = predicate(TypeVars, ArgTypes, Cond, Clauses, Procs, C, Err).

predinfo_arg_types(PredInfo, TypeVars, ArgTypes) :-
	PredInfo = predicate(TypeVars, ArgTypes, _, _, _, _, _).

predinfo_procedures(PredInfo, Procs) :-
	PredInfo = predicate(_, _, _, _, Procs, _, _).

predinfo_set_procedures(PredInfo0, Procedures, PredInfo) :-
	PredInfo0 = predicate(A, B, C, D, _, F, G),
	PredInfo = predicate(A, B, C, D, Procedures, F, G).

predinfo_procids(PredInfo, ProcIds) :-
	predinfo_procedures(PredInfo, Procedures),
	map__keys(Procedures, ProcIds).

predinfo_context(PredInfo, Context) :-
	PredInfo = predicate(_, _, _, _, _, Context, _).

predinfo_is_imported(PredInfo) :-
	predinfo_clauses_info(PredInfo, ClauseInfo),
	ClauseInfo = clauses_info(_, _, _, []).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% Various predicates for accessing the proc_info data structure.

:- interface.

:- pred procinfo_init(list(mode), determinism, term__context, proc_info).
:- mode procinfo_init(input, input, input, output).

:- pred determinism_to_category(determinism, category).
:- mode determinism_to_category(input, output).

:- pred procinfo_declared_determinism(proc_info, determinism).
:- mode procinfo_declared_determinism(input, output).

:- pred procinfo_inferred_determinism(proc_info, category).
:- mode procinfo_inferred_determinism(input, output).

:- pred procinfo_variables(proc_info, varset).
:- mode procinfo_variables(input, output).

:- pred procinfo_vartypes(proc_info, map(var, type)).
:- mode procinfo_vartypes(input, output).

:- pred procinfo_headvars(proc_info, list(var)).
:- mode procinfo_headvars(input, output).

:- pred procinfo_argmodes(proc_info, list(mode)).
:- mode procinfo_argmodes(input, output).

:- pred procinfo_goal(proc_info, hlds__goal).
:- mode procinfo_goal(input, output).

:- pred procinfo_context(proc_info, term__context).
:- mode procinfo_context(input, output).

:- pred procinfo_callinfo(proc_info, call_info).
:- mode procinfo_callinfo(input, output).

:- pred procinfo_arg_registers(proc_info, list(var), map(var, int)).
:- mode procinfo_arg_registers(input, input, output).

:- pred procinfo_set_inferred_determinism(proc_info, category, proc_info).
:- mode procinfo_set_inferred_determinism(input, input, output).

:- pred procinfo_set_goal(proc_info, hlds__goal, proc_info).
:- mode procinfo_set_goal(input, input, output).

:- pred procinfo_arginfo(proc_info, list(arg_info)).
:- mode procinfo_arginfo(in, out).

:- pred procinfo_set_arginfo(proc_info, list(arg_info), proc_info).
:- mode procinfo_set_arginfo(in, in, out).

:- implementation.

	% Some parts of the procedure aren't known yet.  We initialize
	% them to any old garbage which we will later throw away

procinfo_init(Modes, Det, MContext, NewProc) :-
	map__init(BodyTypes),
	goalinfo_init(GoalInfo),
	varset__init(BodyVarSet),
	HeadVars = [],
	determinism_to_category(Det, Category),
	map__init(CallInfo),
	ArgInfo = [],
	ClauseBody = conj([]) - GoalInfo,
	NewProc = procedure(
		Det, BodyVarSet, BodyTypes, HeadVars, Modes,
		ClauseBody, MContext, CallInfo, Category, ArgInfo
	).

determinism_to_category(det, deterministic).
determinism_to_category(semidet, semideterministic).
determinism_to_category(nondet, nondeterministic).
	% The inferred determinism gets initialized to `deterministic'.
	% This is what `det_analysis.nl' wants.  If it turns out
	% that the procedure wasn't deterministic, then det_analysis.nl
	% provide the correct inferred determinism for it.
determinism_to_category(unspecified, deterministic).

procinfo_declared_determinism(ProcInfo, Determinism) :-
	ProcInfo = procedure(Determinism, _, _, _, _, _, _, _, _, _).
procinfo_variables(ProcInfo, VarSet) :-
	ProcInfo = procedure(_, VarSet, _, _, _, _, _, _, _, _).
procinfo_vartypes(ProcInfo, VarTypes) :-
	ProcInfo = procedure(_, _, VarTypes, _, _, _, _, _, _, _).
procinfo_headvars(ProcInfo, HeadVars) :-
	ProcInfo = procedure(_, _, _, HeadVars, _, _, _, _, _, _).
procinfo_argmodes(ProcInfo, ModeInfo) :-
	ProcInfo = procedure(_, _, _, _, ModeInfo, _, _, _, _, _).
procinfo_goal(ProcInfo, Goal) :-
	ProcInfo = procedure(_, _, _, _, _, Goal, _, _, _, _).
procinfo_context(ProcInfo, Context) :-
	ProcInfo = procedure(_, _, _, _, _, _, Context, _, _, _).
procinfo_callinfo(ProcInfo, CallInfo) :-
	ProcInfo = procedure(_, _, _, _, _, _, _, CallInfo, _, _).
procinfo_inferred_determinism(ProcInfo, Category) :-
	ProcInfo = procedure(_, _, _, _, _, _, _, _, Category, _).
procinfo_arginfo(ProcInfo, ArgInfo) :-
	ProcInfo = procedure(_, _, _, _, _, _, _, _, _, ArgInfo).


procinfo_set_inferred_determinism(ProcInfo0, Category, ProcInfo) :-
	ProcInfo0 = procedure(A, B, C, D, E, F, G, H, _, J),
	ProcInfo = procedure(A, B, C, D, E, F, G, H, Category, J).

procinfo_set_goal(ProcInfo0, Goal, ProcInfo) :-
	ProcInfo0 = procedure(A, B, C, D, E, _, G, H, I, J),
	ProcInfo = procedure(A, B, C, D, E, Goal, G, H, I, J).

procinfo_set_arginfo(ProcInfo0, ArgInfo, ProcInfo) :-
	ProcInfo0 = procedure(A, B, C, D, E, F, G, H, I, _),
	ProcInfo = procedure(A, B, C, D, E, F, G, H, I, ArgInfo).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% Access predicates for the hlds__goal_info data structure.

:- interface.

:- pred goalinfo_init(hlds__goal_info).
:- mode goalinfo_init(output).

:- type liveness == map(var, is_live).

:- pred goalinfo_liveness(hlds__goal_info, liveness).
:- mode goalinfo_liveness(input, output).

:- pred goalinfo_set_liveness(hlds__goal_info, liveness, hlds__goal_info).
:- mode goalinfo_set_liveness(input, input, output).

:- pred goalinfo_declared_determinism(hlds__goal_info, determinism).
:- mode goalinfo_declared_determinism(input, output).

:- pred goalinfo_inferred_determinism(hlds__goal_info, category).
:- mode goalinfo_inferred_determinism(input, output).

:- pred goalinfo_set_inferred_determinism(hlds__goal_info, category,
					  hlds__goal_info).
:- mode goalinfo_set_inferred_determinism(input, input, output).

:- pred goalinfo_get_nonlocals(hlds__goal_info, set(var)).
:- mode goalinfo_get_nonlocals(input, output).

:- pred goalinfo_set_nonlocals(hlds__goal_info, set(var), hlds__goal_info).
:- mode goalinfo_set_nonlocals(input, input, output).

	% The instmap delta stores the final instantiatedness
	% of the non-local variables whose instantiatedness
	% changed.

:- type instmap_delta == map(var, inst).

:- pred goalinfo_get_instmap_delta(hlds__goal_info, instmap_delta).
:- mode goalinfo_get_instmap_delta(input, output).

:- pred goalinfo_set_instmap_delta(hlds__goal_info, instmap_delta,
				hlds__goal_info).
:- mode goalinfo_set_instmap_delta(input, input, output).

/***** currently not used and not implemented
:- pred liveness_livevars(map(var, is_live), list(var)).
:- mode liveness_livevars(input, output).
*****/

:- pred goalinfo_context(hlds__goal_info, term__context).
:- mode goalinfo_context(input, output).

:- pred goalinfo_set_context(hlds__goal_info, term__context, hlds__goal_info).
:- mode goalinfo_set_context(input, input, output).

%-----------------------------------------------------------------------------%

:- implementation.

goalinfo_init(GoalInfo) :-
	DeclaredDet = unspecified,
	InferredDet = nondeterministic, 
	map__init(Liveness),
	map__init(InstMapDelta),
	set__init(NonLocals),
	term__context_init("", 0, Context),
	GoalInfo = goalinfo(Liveness, DeclaredDet, InferredDet,
				InstMapDelta, Context, NonLocals).

goalinfo_liveness(GoalInfo, Liveness) :-
	GoalInfo = goalinfo(Liveness, _, _, _, _, _).

goalinfo_set_liveness(GoalInfo0, Liveness, GoalInfo) :-
	GoalInfo0 = goalinfo(_, B, C, D, E, F),
	GoalInfo = goalinfo(Liveness, B, C, D, E, F).

goalinfo_declared_determinism(GoalInfo, DeclaredDeterminism) :-
	GoalInfo = goalinfo(_, DeclaredDeterminism, _, _, _, _).

goalinfo_inferred_determinism(GoalInfo, InferredDeterminism) :-
	GoalInfo = goalinfo(_, _, InferredDeterminism, _, _, _).

goalinfo_set_inferred_determinism(GoalInfo0, InferredDeterminism, GoalInfo) :-
	GoalInfo0 = goalinfo(A, B, _, D, E, F),
	GoalInfo = goalinfo(A, B, InferredDeterminism, D, E, F).

goalinfo_get_instmap_delta(GoalInfo, InstMapDelta) :-
	GoalInfo = goalinfo(_, _, _, InstMapDelta, _, _).

goalinfo_set_instmap_delta(GoalInfo0, InstMapDelta, GoalInfo) :-
	GoalInfo0 = goalinfo(A, B, C, _, E, F),
	GoalInfo = goalinfo(A, B, C, InstMapDelta, E, F).

/*** This is a specification, not an implementation.
     It's not mode-correct.
liveness_livevars(Liveness, LiveVars) :-
	solutions(X, map__search(Liveness, X, live), LiveVars).
***/

goalinfo_context(GoalInfo, Context) :-
	GoalInfo = goalinfo(_, _, _, _, Context, _).

goalinfo_set_context(GoalInfo0, Context, GoalInfo) :-
	GoalInfo0 = goalinfo(A, B, C, D, _, F),
	GoalInfo = goalinfo(A, B, C, D, Context, F).

goalinfo_get_nonlocals(GoalInfo, NonLocals) :-
	GoalInfo = goalinfo(_, _, _, _, _, NonLocals).

goalinfo_set_nonlocals(GoalInfo0, NonLocals, GoalInfo) :-
	GoalInfo0 = goalinfo(A, B, C, D, E, _),
	GoalInfo  = goalinfo(A, B, C, D, E, NonLocals).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
