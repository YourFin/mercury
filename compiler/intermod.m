%-----------------------------------------------------------------------------%
% Copyright (C) 1996-2003 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% file: intermod.m
% main author: stayl
%
% This module writes out the interface for inter-module optimization.
% The .opt file includes:
%	- The clauses for exported preds that can be inlined.
%	- The clauses for exported preds that have higher-order pred arguments.
%	- The pred/mode declarations for local predicates that the
%	  above clauses use.
% 	- Non-exported types, insts and modes used by the above
%	- Pragma reserve_tag or foreign_type declarations for any types
%	  output due to the line above
%	- :- import_module declarations to import stuff used by the above.
%	- pragma declarations for the exported preds.
%	- pragma foreign_header declarations if any pragma_foreign_code 
%	  preds are written.
% All these items should be module qualified.
%
% This module also contains predicates to read in the .opt files and
% to adjust the import status of local predicates which are exported for
% intermodule optimization.
%	
% Note that predicates which call predicates that do not have mode or
% determinism declarations do not have clauses exported, since this would
% require running mode analysis and determinism analysis before writing the
% .opt file, significantly increasing compile time for a very small gain.
%
%-----------------------------------------------------------------------------%

:- module transform_hlds__intermod.

%-----------------------------------------------------------------------------%

:- interface.

:- import_module hlds__hlds_module.
:- import_module parse_tree__modules.
:- import_module parse_tree__prog_data.
:- import_module parse_tree__prog_io.

:- import_module io, bool.

:- pred intermod__write_optfile(module_info, module_info,
				io__state, io__state).
:- mode intermod__write_optfile(in, out, di, uo) is det.

	% Add the items from the .opt files of imported modules to
	% the items for this module.
:- pred intermod__grab_optfiles(module_imports, module_imports, bool,
				io__state, io__state).
:- mode intermod__grab_optfiles(in, out, out, di, uo) is det.

	% Make sure that local preds which have been exported in the .opt
	% file get an exported(_) label.
:- pred intermod__adjust_pred_import_status(module_info, module_info,
		io__state, io__state).
:- mode intermod__adjust_pred_import_status(in, out, di, uo) is det.

:- type opt_file_type
	--->	opt
	;	trans_opt
	.

	% intermod__update_error_status(OptFileType, FileName, Error, Messages,
	% 	Status0, Status)
	%
	% Work out whether any fatal errors have occurred while reading
	% `.opt' files, updating Status0 if there were fatal errors.
	%
	% A missing `.opt' file is only a fatal error if
	% `--warn-missing-opt-files --halt-at-warn' was passed
	% the compiler.
	%
	% Syntax errors in `.opt' files are always fatal.
	%
	% This is also used by trans_opt.m for reading `.trans_opt' files.
:- pred intermod__update_error_status(opt_file_type, string, module_error,
		message_list, bool, bool, io__state, io__state).
:- mode intermod__update_error_status(in, in, in, in, in, out, di, uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs__foreign.
:- import_module check_hlds__mode_util.
:- import_module check_hlds__type_util.
:- import_module check_hlds__typecheck.
:- import_module hlds__goal_util.
:- import_module hlds__hlds_data.
:- import_module hlds__hlds_goal.
:- import_module hlds__hlds_out.
:- import_module hlds__hlds_pred.
:- import_module hlds__instmap.
:- import_module hlds__passes_aux.
:- import_module hlds__special_pred.
:- import_module libs__globals.
:- import_module libs__options.
:- import_module ll_backend__llds.
:- import_module parse_tree__inst.
:- import_module parse_tree__mercury_to_mercury.
:- import_module parse_tree__modules.
:- import_module parse_tree__prog_data.
:- import_module parse_tree__prog_io.
:- import_module parse_tree__prog_out.
:- import_module parse_tree__prog_util.
:- import_module transform_hlds__inlining.

:- import_module assoc_list, dir, getopt, int, list, map, multi_map, require.
:- import_module set, std_util, string, term, varset.

%-----------------------------------------------------------------------------%

% Open the file "<module-name>.opt.tmp", and write out the
% declarations and clauses for intermodule optimization.
% Note that update_interface and touch_interface_datestamp
% are called from mercury_compile.m since they must be called
% after unused_args.m appends its information to the .opt.tmp
% file.

intermod__write_optfile(ModuleInfo0, ModuleInfo) -->
	% We don't want to output line numbers in the .opt files,
	% since that causes spurious changes to the .opt files
	% when you make trivial changes (e.g. add comments) to the source files.
	globals__io_lookup_bool_option(line_numbers, LineNumbers),
	globals__io_set_option(line_numbers, bool(no)),

	{ module_info_name(ModuleInfo0, ModuleName) },
	module_name_to_file_name(ModuleName, ".opt.tmp", yes, TmpName),
	io__open_output(TmpName, Result2),
	(
		{ Result2 = error(Err2) },
		{ io__error_message(Err2, Msg2) },
		io__write_string(Msg2),
		io__set_exit_status(1),
		{ ModuleInfo = ModuleInfo0 }
	;
		{ Result2 = ok(FileStream) },
		io__set_output_stream(FileStream, OutputStream),
		{ module_info_predids(ModuleInfo0, RealPredIds) },
		{ module_info_assertion_table(ModuleInfo0, AssertionTable) },
		{ assertion_table_pred_ids(AssertionTable, AssertPredIds) },
		{ list__append(AssertPredIds, RealPredIds, PredIds) },
		{ init_intermod_info(ModuleInfo0, IntermodInfo0) },
		globals__io_lookup_int_option(
			intermod_inline_simple_threshold, Threshold),
		globals__io_lookup_bool_option(deforestation, Deforestation),
		globals__io_lookup_int_option(higher_order_size_limit,
			HigherOrderSizeLimit),
		{ intermod__gather_preds(PredIds, yes, Threshold,
			HigherOrderSizeLimit, Deforestation,
			IntermodInfo0, IntermodInfo1) },
		{ intermod__gather_instances(IntermodInfo1,
			IntermodInfo2) },
		{ intermod__gather_types(IntermodInfo2,
			IntermodInfo) },
		intermod__write_intermod_info(IntermodInfo),
		{ intermod_info_get_module_info(ModuleInfo1,
			IntermodInfo, _) },
		io__set_output_stream(OutputStream, _),
		io__close_output(FileStream),
		globals__io_lookup_bool_option(intermod_unused_args,
			UnusedArgs),
		( { UnusedArgs = yes } ->
			{ do_adjust_pred_import_status(IntermodInfo,
				ModuleInfo1, ModuleInfo) }
		;
			{ ModuleInfo = ModuleInfo1 }
		)
	),
	% restore the option setting that we overrode above
	globals__io_set_option(line_numbers, bool(LineNumbers)).

	% a collection of stuff to go in the .opt file
:- type intermod_info
		 ---> info(
			set(module_name),	% modules to import
			set(pred_id), 		% preds to output clauses for
			set(pred_id),	 	% preds to output decls for
			assoc_list(class_id, hlds_instance_defn),
						% instances declarations
						% to write
			assoc_list(type_ctor, hlds_type_defn),
						% type declarations
						% to write
			unit,
			module_info,
			bool,			% do the c_header_codes for
				% the module need writing, yes if there
				% are pragma_foreign_code procs being exported
			map(prog_var, type),	% Vartypes and tvarset for the
			tvarset			% current pred
		).

:- pred init_intermod_info(module_info::in, intermod_info::out) is det.

init_intermod_info(ModuleInfo, IntermodInfo) :-
	set__init(Modules),
	set__init(Procs),
	set__init(ProcDecls),
	map__init(VarTypes),
	varset__init(TVarSet),
	Instances = [],
	Types = [],
	IntermodInfo = info(Modules, Procs, ProcDecls, Instances, Types,
			unit, ModuleInfo, no, VarTypes, TVarSet).
			
%-----------------------------------------------------------------------------%
	% Predicates to gather stuff to output to .opt file.

:- pred intermod__gather_preds(list(pred_id)::in, bool::in, int::in,
	int::in, bool::in, intermod_info::in, intermod_info::out) is det.

intermod__gather_preds(AllPredIds, CollectTypes,
		InlineThreshold, HigherOrderSizeLimit, Deforestation) -->
	% first gather exported preds
	{ ProcessLocalPreds = no },
	intermod__gather_pred_list(AllPredIds, ProcessLocalPreds,
		CollectTypes, InlineThreshold, HigherOrderSizeLimit,
		Deforestation),

	% then gather preds used by exported preds (recursively)
	{ set__init(ExtraExportedPreds0) },
	intermod__gather_preds_2(ExtraExportedPreds0, CollectTypes,
		InlineThreshold, HigherOrderSizeLimit, Deforestation).

:- pred intermod__gather_preds_2(set(pred_id)::in, bool::in, int::in,
	int::in, bool::in, intermod_info::in, intermod_info::out) is det.

intermod__gather_preds_2(ExtraExportedPreds0, CollectTypes,
		InlineThreshold, HigherOrderSizeLimit, Deforestation) -->
	intermod_info_get_pred_decls(ExtraExportedPreds),
	{ NewlyExportedPreds = set__to_sorted_list(
		ExtraExportedPreds `set__difference` ExtraExportedPreds0) },
	( { NewlyExportedPreds = [] } ->
		[]
	;
		{ ProcessLocalPreds = yes },
		intermod__gather_pred_list(NewlyExportedPreds,
			ProcessLocalPreds, CollectTypes,
			InlineThreshold, HigherOrderSizeLimit, Deforestation),
		intermod__gather_preds_2(ExtraExportedPreds, CollectTypes,
			InlineThreshold, HigherOrderSizeLimit, Deforestation)
	).

:- pred intermod__gather_pred_list(list(pred_id)::in, bool::in, bool::in,
	int::in, int::in, bool::in, intermod_info::in, intermod_info::out)
	is det.

intermod__gather_pred_list([], _, _, _, _, _) --> [].
intermod__gather_pred_list([PredId | PredIds], ProcessLocalPreds, CollectTypes,
		InlineThreshold, HigherOrderSizeLimit, Deforestation) -->
	intermod_info_get_module_info(ModuleInfo0),
	{ module_info_preds(ModuleInfo0, PredTable0) },
	{ map__lookup(PredTable0, PredId, PredInfo0) },
	{ module_info_type_spec_info(ModuleInfo0, TypeSpecInfo) },
	{ TypeSpecInfo = type_spec_info(_, TypeSpecForcePreds, _, _) },
	{ pred_info_clauses_info(PredInfo0, ClausesInfo0) },
	(
		%
		% XXX hlds_out__write_clause needs to be changed to
		% output explicit type qualifications to avoid type
		% ambiguity errors in clauses written to `.opt' files.
		%
		{ clauses_info_explicit_vartypes(ClausesInfo0,
			ExplicitVarTypes) },
		{ map__is_empty(ExplicitVarTypes) },

		{ intermod__should_be_processed(ProcessLocalPreds, PredId,
			PredInfo0, TypeSpecForcePreds, InlineThreshold,
			HigherOrderSizeLimit, Deforestation, ModuleInfo0) }
	->
		=(IntermodInfo0),
		% Write a declaration to the `.opt' file for
		% `exported_to_submodules' predicates.
		intermod__add_proc(PredId, DoWrite0),
		{ clauses_info_clauses(ClausesInfo0, Clauses0) },
		( { DoWrite0 = yes } ->
			{ clauses_info_vartypes(ClausesInfo0, VarTypes) },
			{ pred_info_typevarset(PredInfo0, TVarSet) },
			intermod_info_set_var_types(VarTypes),
			intermod_info_set_tvarset(TVarSet),
			intermod__traverse_clauses(Clauses0, Clauses, DoWrite)
		;
			{ Clauses = Clauses0 },
			{ DoWrite = no }
		),
		( { DoWrite = yes } ->
			{ clauses_info_set_clauses(ClausesInfo0, Clauses,
				ClausesInfo) },
			{ pred_info_set_clauses_info(PredInfo0, ClausesInfo,
					PredInfo) },	
			{ map__det_update(PredTable0, PredId,
					PredInfo, PredTable) },
			{ module_info_set_preds(ModuleInfo0, PredTable,
					ModuleInfo) },
			intermod_info_get_preds(Preds0),
			( { pred_info_pragma_goal_type(PredInfo) } ->
				% The header code must be written since
				% it could be used by the pragma_foreign_code.
				intermod_info_set_write_header
			;
				[]
			),
			{ set__insert(Preds0, PredId, Preds) },
			intermod_info_set_preds(Preds),
			intermod_info_set_module_info(ModuleInfo)
		;
			% Remove any items added for the clauses
			% for this predicate.
			:=(IntermodInfo0)
		)
	;
		[]
	),
	intermod__gather_pred_list(PredIds, ProcessLocalPreds, CollectTypes,
		InlineThreshold, HigherOrderSizeLimit, Deforestation).


:- pred intermod__should_be_processed(bool::in, pred_id::in, pred_info::in,
		set(pred_id)::in, int::in, int::in, bool::in,
		module_info::in) is semidet.

intermod__should_be_processed(ProcessLocalPreds, PredId, PredInfo,
		TypeSpecForcePreds, InlineThreshold, HigherOrderSizeLimit,
		Deforestation, ModuleInfo) :-
	(
		ProcessLocalPreds = no,
		( pred_info_is_exported(PredInfo)
		; pred_info_is_exported_to_submodules(PredInfo)
		)
	;
		ProcessLocalPreds = yes,
		pred_info_import_status(PredInfo, local)
	),
	(
		pred_info_clauses_info(PredInfo, ClauseInfo),
		clauses_info_clauses(ClauseInfo, Clauses),

		pred_info_procids(PredInfo, [ProcId | _ProcIds]),
		pred_info_procedures(PredInfo, Procs),
		map__lookup(Procs, ProcId, ProcInfo),

		% At this point, the goal size includes some dummy unifications
		% HeadVar1 = X, HeadVar2 = Y, etc. which will be optimized away
		% later.  To counter for this, we add the arity to the
		% size thresholds.
		pred_info_arity(PredInfo, Arity),

		% Predicates with `class_method' markers contain
		% class_method_call goals which can't be written
		% to `.opt' files (they can't be read back in).
		% They will be recreated in the importing module.
		pred_info_get_markers(PredInfo, Markers),
		\+ check_marker(Markers, class_method),
		\+ check_marker(Markers, class_instance_method),

		% Don't write stub clauses to `.opt' files.
		\+ check_marker(Markers, stub),

		% Don't export builtins since they will be
		% recreated in the importing module anyway.
		\+ is_unify_or_compare_pred(PredInfo),
		\+ pred_info_is_builtin(PredInfo),

		% These will be recreated in the importing module.
		\+ set__member(PredId, TypeSpecForcePreds),

		(
			inlining__is_simple_clause_list(Clauses,
				InlineThreshold + Arity),
			pred_info_get_markers(PredInfo, Markers),
			\+ check_marker(Markers, no_inline),
			proc_info_eval_method(ProcInfo, eval_normal)
		;
			pred_info_requested_inlining(PredInfo)
		;
			has_ho_input(ModuleInfo, ProcInfo),
			clause_list_size(Clauses, GoalSize),
			GoalSize =< HigherOrderSizeLimit + Arity
		;
			Deforestation = yes,
			% Double the inline-threshold since
			% goals we want to deforest will have at
			% least two disjuncts. This allows one
			% simple goal in each disjunct.  The
			% disjunction adds one to the goal size,
			% hence the `+1'.
			DeforestThreshold = InlineThreshold * 2 + 1,
			inlining__is_simple_clause_list(Clauses,
				DeforestThreshold + Arity),
			clause_list_is_deforestable(PredId, Clauses)
		)
	;
		% promises that are in the interface should always get
		% included in the .opt file.
		pred_info_get_goal_type(PredInfo, promise(_))
	).

:- pred intermod__traverse_clauses(list(clause)::in, list(clause)::out,
		bool::out, intermod_info::in, intermod_info::out) is det.

intermod__traverse_clauses([], [], yes) --> [].
intermod__traverse_clauses([clause(P, Goal0, L, C) | Clauses0],
			[clause(P, Goal, L, C) | Clauses], DoWrite) -->
	intermod__traverse_goal(Goal0, Goal, DoWrite1),
	( { DoWrite1 = yes } ->
		intermod__traverse_clauses(Clauses0, Clauses, DoWrite)
	;
		{ Clauses = Clauses0 },
		{ DoWrite = no }
	).

:- pred has_ho_input(module_info::in, proc_info::in) is semidet.

has_ho_input(ModuleInfo, ProcInfo) :-
	proc_info_headvars(ProcInfo, HeadVars),
	proc_info_argmodes(ProcInfo, ArgModes),
	proc_info_vartypes(ProcInfo, VarTypes),
	check_for_ho_input_args(ModuleInfo, HeadVars, ArgModes, VarTypes).

:- pred check_for_ho_input_args(module_info::in, list(prog_var)::in,
		list(mode)::in, map(prog_var, type)::in) is semidet.

check_for_ho_input_args(ModuleInfo, [HeadVar | HeadVars],
			[ArgMode | ArgModes], VarTypes) :-
	(
		mode_is_input(ModuleInfo, ArgMode),
		map__lookup(VarTypes, HeadVar, Type),
		classify_type(Type, ModuleInfo, pred_type)
	;
		check_for_ho_input_args(ModuleInfo, HeadVars,
							ArgModes, VarTypes)
	).

	% Rough guess: a goal is deforestable if it contains a single
	% top-level branched goal and is recursive.
:- pred clause_list_is_deforestable(pred_id::in, list(clause)::in) is semidet.

clause_list_is_deforestable(PredId, Clauses)  :-
	some [Clause1] (
		list__member(Clause1, Clauses),
		Clause1 = clause(_, Goal1, _, _),
		goal_calls_pred_id(Goal1, PredId)
	),
	(
		Clauses = [_, _ | _]
	;
		Clauses = [Clause2],
		Clause2 = clause(_, Goal2, _, _),
		goal_to_conj_list(Goal2, GoalList),
		goal_contains_one_branched_goal(GoalList)
	).

:- pred goal_contains_one_branched_goal(list(hlds_goal)::in) is semidet.

goal_contains_one_branched_goal(GoalList) :-
	goal_contains_one_branched_goal(GoalList, no).

:- pred goal_contains_one_branched_goal(list(hlds_goal)::in,
		bool::in) is semidet.

goal_contains_one_branched_goal([], yes).
goal_contains_one_branched_goal([Goal | Goals], FoundBranch0) :-
	Goal = GoalExpr - _,
	(
		goal_is_branched(GoalExpr),
		FoundBranch0 = no,
		FoundBranch = yes
	;
		goal_is_atomic(GoalExpr),
		FoundBranch = FoundBranch0
	),
	goal_contains_one_branched_goal(Goals, FoundBranch).

	% Go over the goal of an exported proc looking for proc decls, types,
	% insts and modes that we need to write to the optfile.
:- pred intermod__traverse_goal(hlds_goal::in, hlds_goal::out, bool::out,
			intermod_info::in, intermod_info::out) is det.

intermod__traverse_goal(conj(Goals0) - Info, conj(Goals) - Info, DoWrite) -->
	intermod__traverse_list_of_goals(Goals0, Goals, DoWrite).

intermod__traverse_goal(par_conj(Goals0) - Info, par_conj(Goals) - Info,
		DoWrite) -->
	intermod__traverse_list_of_goals(Goals0, Goals, DoWrite).

intermod__traverse_goal(disj(Goals0) - Info, disj(Goals) - Info, DoWrite) -->
	intermod__traverse_list_of_goals(Goals0, Goals, DoWrite).

intermod__traverse_goal(Goal, Goal, DoWrite) -->
	{ Goal = call(PredId, _, _, _, _, _) - _ },

	%
	% Ensure that the called predicate will be exported.
	%
	intermod__add_proc(PredId, DoWrite).

intermod__traverse_goal(generic_call(CallType, B,C,D) - Info,
			generic_call(CallType, B,C,D) - Info, DoWrite) -->
	{ CallType = higher_order(_, _, _, _), DoWrite = yes
	; CallType = class_method(_, _, _, _), DoWrite = no
	; CallType = unsafe_cast, DoWrite = no
	; CallType = aditi_builtin(_, _), DoWrite = yes
	}.

intermod__traverse_goal(switch(A, B, Cases0) - Info,
		switch(A, B, Cases) - Info, DoWrite) -->
	intermod__traverse_cases(Cases0, Cases, DoWrite).

	% Export declarations for preds used in higher order pred constants
	% or function calls.
intermod__traverse_goal(unify(LVar, RHS0, C, D, E) - Info,
			unify(LVar, RHS, C, D, E) - Info, DoWrite) -->
	intermod__module_qualify_unify_rhs(LVar, RHS0, RHS, DoWrite).

intermod__traverse_goal(not(Goal0) - Info, not(Goal) - Info, DoWrite) -->
	intermod__traverse_goal(Goal0, Goal, DoWrite).

intermod__traverse_goal(some(Vars, CanRemove, Goal0) - Info,
		some(Vars, CanRemove, Goal) - Info, DoWrite) -->
	intermod__traverse_goal(Goal0, Goal, DoWrite).

intermod__traverse_goal(if_then_else(Vars, Cond0, Then0, Else0) - Info,
		if_then_else(Vars, Cond, Then, Else) - Info, DoWrite) -->
	intermod__traverse_goal(Cond0, Cond, DoWrite1),
	intermod__traverse_goal(Then0, Then, DoWrite2),
	intermod__traverse_goal(Else0, Else, DoWrite3),
	{ bool__and_list([DoWrite1, DoWrite2, DoWrite3], DoWrite) }.

	% Inlineable exported pragma_foreign_code goals can't use any
	% non-exported types, so we just write out the clauses. 
intermod__traverse_goal(foreign_proc(A,B,C,D,E,F,G) - Info,
		foreign_proc(A,B,C,D,E,F,G) - Info, yes) --> [].

intermod__traverse_goal(shorthand(_) - _, _, _) -->
	% these should have been expanded out by now
	{ error("intermod__traverse_goal: unexpected shorthand") }.


:- pred intermod__traverse_list_of_goals(hlds_goals::in, hlds_goals::out,
		bool::out, intermod_info::in, intermod_info::out) is det.

intermod__traverse_list_of_goals([], [], yes) --> [].
intermod__traverse_list_of_goals([Goal0 | Goals0], [Goal | Goals], DoWrite) -->
	intermod__traverse_goal(Goal0, Goal, DoWrite1),
	( { DoWrite1 = yes } ->
		intermod__traverse_list_of_goals(Goals0, Goals, DoWrite)
	;
		{ DoWrite = no },
		{ Goals = Goals0 }
	).

:- pred intermod__traverse_cases(list(case)::in, list(case)::out, bool::out,
			intermod_info::in, intermod_info::out) is det.

intermod__traverse_cases([], [], yes) --> [].
intermod__traverse_cases([case(F, Goal0) | Cases0],
		[case(F, Goal) | Cases], DoWrite) -->
	intermod__traverse_goal(Goal0, Goal, DoWrite1),
	( { DoWrite1 = yes } ->
		intermod__traverse_cases(Cases0, Cases, DoWrite)
	;
		{ DoWrite = no },
		{ Cases = Cases0 }
	).

	%
	% intermod__add_proc/4 tries to do what ever is necessary to
	% ensure that the specified predicate will be exported,
	% so that it can be called from clauses in the `.opt' file.
	% If it can't, then it returns DoWrite = no, which will
	% prevent the caller from being included in the `.opt' file.
	%
	% If a proc called within an exported proc is local, we need
	% to add a declaration for the called proc to the .opt file.
	% If a proc called within an exported proc is from a different
	% module, we need to include an `:- import_module' declaration
	% to import that module in the `.opt' file.
	%
:- pred intermod__add_proc(pred_id::in, bool::out,
		intermod_info::in, intermod_info::out) is det.

intermod__add_proc(PredId, DoWrite) -->
	( { invalid_pred_id(PredId) } ->
		% This will happen for type class instance methods
		% defined using the clause syntax.  Currently we
		% can't handle intermodule-optimization of those.
		{ DoWrite = no }
	;
		intermod__add_proc_2(PredId, DoWrite)
	).

:- pred intermod__add_proc_2(pred_id::in, bool::out,
		intermod_info::in, intermod_info::out) is det.

intermod__add_proc_2(PredId, DoWrite) -->
	intermod_info_get_module_info(ModuleInfo),
	{ module_info_pred_info(ModuleInfo, PredId, PredInfo) },
	{ pred_info_import_status(PredInfo, Status) },
	{ pred_info_procids(PredInfo, ProcIds) },
	{ pred_info_get_markers(PredInfo, Markers) },
	(
		%
		% Calling compiler-generated procedures is fine;
		% we don't need to output declarations for them to
		% the `.opt' file, since they will be recreated every
		% time anyway.
		%
		{ is_unify_or_compare_pred(PredInfo) }
	->
		{ DoWrite = yes }
	;
		%
		% Don't write the caller to the `.opt' file if it calls
		% a pred without mode or determinism decls, because we'd
		% need to include the mode decls for the callee in the `.opt'
		% file and (since writing the `.opt' file happens before mode
		% inference) we can't do that because we don't know what
		% the modes are.
		%
		% XXX This prevents intermodule optimizations in such cases,
		% which is a pity.
		%
		{
			check_marker(Markers, infer_modes)
		;
			pred_info_procedures(PredInfo, Procs),
			list__member(ProcId, ProcIds),
			map__lookup(Procs, ProcId, ProcInfo),
			proc_info_declared_determinism(ProcInfo, no)
		}
	->
		{ DoWrite = no }
	;
		% Goals which call impure predicates cannot be written
		% due to limitations in mode analysis. The problem is that
		% only head unifications are allowed to be reordered with
		% impure goals.
		% 	
		% e.g
		%	p(A::in, B::in, C::out) :- impure foo(A, B, C).
		% becomes
		% 	p(HeadVar1, HeadVar2, HeadVar3) :-
		%		A = HeadVar1, B = HeadVar2, C = HeadVar3,
		% 		impure foo(A, B, C).
		% 
		% In the clauses written to `.opt' files, the head
		% unifications are already expanded, and are expanded
		% again when the `.opt' file is read in. The `C = HeadVar3'
		% unification cannot be reordered with the impure goal,
		% resulting in a mode error. Fixing this in mode analysis
		% would be tricky.
		%
		% See tests/valid/impure_intermod.m.
		{ pred_info_get_purity(PredInfo, impure) }
	->	
		{ DoWrite = no }
	;
		%
		% If a pred whose code we're going to put in the .opt file
		% calls a predicate which is exported, then we don't
		% need to do anything special.
		%
		{ Status = exported ; Status = external(interface) }
	->
		{ DoWrite = yes }
	;
		%
		% Declarations for class methods will be recreated
		% from the class declaration in the `.opt' file.
		% Declarations for local classes are always written
		% to the `.opt' file.
		%
		{ pred_info_get_markers(PredInfo, Markers) },
		{ check_marker(Markers, class_method) }
	->
		{ DoWrite = yes }
	;
		%
		% If a pred whose code we're going to put in the `.opt' file
		% calls a predicate which is local to that module, then
		% we need to put the declaration for the called predicate
		% in the `.opt' file.
		%
		{ import_status_to_write(Status) }
	->
		{ DoWrite = yes },
		intermod_info_get_pred_decls(PredDecls0),
		{ set__insert(PredDecls0, PredId, PredDecls) },
		intermod_info_set_pred_decls(PredDecls)
	;
		{ Status = imported(_)
		; Status = opt_imported
		}
	->
		%
		% imported pred - add import for module
		%
		{ DoWrite = yes },
		{ pred_info_module(PredInfo, PredModule) },
		intermod_info_get_modules(Modules0),
		{ set__insert(Modules0, PredModule, Modules) },
		intermod_info_set_modules(Modules)
	;
		{ error("intermod__add_proc: unexpected status") }
	).

	% Resolve overloading and module qualify everything in a unify_rhs.
:- pred intermod__module_qualify_unify_rhs(prog_var::in, unify_rhs::in,
		unify_rhs::out, bool::out, intermod_info::in,
		intermod_info::out) is det.

intermod__module_qualify_unify_rhs(_, var(Var), var(Var), yes) --> [].

intermod__module_qualify_unify_rhs(_LVar,
		lambda_goal(A,B,EvalMethod,C,D,E,Modes,G,Goal0),
		lambda_goal(A,B,EvalMethod,C,D,E,Modes,G,Goal), DoWrite) -->
	intermod__traverse_goal(Goal0, Goal, DoWrite).

	% Fully module-qualify the right-hand-side of a unification.
	% For function calls and higher-order terms, call intermod__add_proc
	% so that the predicate or function will be exported if necessary.
intermod__module_qualify_unify_rhs(_LVar, functor(Functor, E, Vars),
				functor(Functor, E, Vars), DoWrite) -->
	(
		%
		% Is this a higher-order predicate or higher-order function
		% term?
		%
		{ Functor = pred_const(PredId, _, _) }
	->
		%
		% Yes, the unification creates a higher-order term.
		% Make sure that the predicate/function is exported.
		%
		intermod__add_proc(PredId, DoWrite)
	;
		%
		% It's an ordinary constructor, or a constant of a builtin
		% type, so just leave it alone.
		%
		% Constructors are module qualified by post_typecheck.m.
		%
		% Function calls and higher-order function applications
		% are transformed into ordinary calls and higher-order calls
		% by post_typecheck.m, so they can't occur here.
		%
		{ DoWrite = yes }
	).

%-----------------------------------------------------------------------------%

:- pred intermod__gather_instances(intermod_info::in,
		intermod_info::out) is det.

intermod__gather_instances -->
	intermod_info_get_module_info(ModuleInfo),
	{ module_info_instances(ModuleInfo, Instances) },
	map__foldl(intermod__gather_instances_2(ModuleInfo), Instances).

:- pred intermod__gather_instances_2(module_info::in, class_id::in,
		list(hlds_instance_defn)::in,
		intermod_info::in, intermod_info::out) is det.

intermod__gather_instances_2(ModuleInfo, ClassId, InstanceDefns) -->
	list__foldl(intermod__gather_instances_3(ModuleInfo, ClassId),
		InstanceDefns).

:- pred intermod__gather_instances_3(module_info::in, class_id::in,
	hlds_instance_defn::in, intermod_info::in, intermod_info::out) is det.
		
intermod__gather_instances_3(ModuleInfo, ClassId, InstanceDefn) -->
	{ InstanceDefn = hlds_instance_defn(A, Status, C, D, E, Interface0,
				MaybePredProcIds, H, I) },
	(
		%
		% The bodies are always stripped from instance declarations
		% before writing them to `int' files, so the full instance
		% declaration should be written even for exported instances.
		%
		{ status_defined_in_this_module(Status, yes) }
	->
		=(IntermodInfo0),
		(
			{ Interface0 = concrete(Methods0) },
			{ MaybePredProcIds = yes(ClassProcs) ->
				GetPredId =
				    (pred(Proc::in, PredId::out) is det :-
					Proc = hlds_class_proc(PredId, _)
				    ),
				list__map(GetPredId, ClassProcs, ClassPreds0),

				% The interface is sorted on pred_id.
				list__remove_adjacent_dups(ClassPreds0,
					ClassPreds),
				assoc_list__from_corresponding_lists(
					ClassPreds, Methods0, MethodAL)
			;
				error(
	"intermod__gather_instances_3: method pred_proc_ids not filled in")
			},
			{ list__map_foldl(
				intermod__qualify_instance_method(ModuleInfo),
				MethodAL, Methods, [], PredIds) },
			list__map_foldl(intermod__add_proc, PredIds, 
				DoWriteMethodsList),
			{ bool__and_list(DoWriteMethodsList, DoWriteMethods) },
			(
				{ DoWriteMethods = yes },
				{ Interface = concrete(Methods) }
			;
				{ DoWriteMethods = no },

				%
				% Write an abstract instance declaration
				% if any of the methods cannot be written
				% to the `.opt' file for any reason.
				%
				{ Interface = abstract },

				%
				% Don't write declarations for any of the
				% methods if one can't be written.
				%
				:=(IntermodInfo0)
			)
		;
			{ Interface0 = abstract },
			{ Interface = Interface0 }
		),
		(
			%
			% Don't write an abstract instance declaration
			% if the declaration is already in the `.int' file.
			%
			{
				Interface = abstract
			=>
				status_is_exported(Status, no)
			}
		->
			{ InstanceDefnToWrite = hlds_instance_defn(A, Status,
					C, D, E, Interface, MaybePredProcIds,
					H, I) },
			intermod_info_get_instances(Instances0),
			intermod_info_set_instances(
				[ClassId - InstanceDefnToWrite | Instances0])
		;
			[]
		)
	;
		[]
	).

	% Resolve overloading of instance methods before writing them
	% to the `.opt' file.
:- pred intermod__qualify_instance_method(module_info::in,
		pair(pred_id, instance_method)::in, instance_method::out,
		list(pred_id)::in, list(pred_id)::out) is det.

intermod__qualify_instance_method(ModuleInfo,
		MethodCallPredId - InstanceMethod0,
		InstanceMethod, PredIds0, PredIds) :-
	module_info_pred_info(ModuleInfo, MethodCallPredId,
		MethodCallPredInfo),
	pred_info_arg_types(MethodCallPredInfo, MethodCallTVarSet, _,
		MethodCallArgTypes),
	InstanceMethod0 = instance_method(PredOrFunc, MethodName,
			InstanceMethodDefn0, MethodArity, MethodContext),
	(
		InstanceMethodDefn0 = name(InstanceMethodName0),
		PredOrFunc = function,
		(
			find_func_matching_instance_method(ModuleInfo,
				InstanceMethodName0, MethodArity,
				MethodCallTVarSet, MethodCallArgTypes,
				MaybePredId, InstanceMethodName)
		->
			( MaybePredId = yes(PredId) ->
				PredIds = [PredId | PredIds0]
			;
				PredIds = PredIds0
			),
			InstanceMethodDefn = name(InstanceMethodName)
		;
			% This will force intermod__add_proc to
			% return DoWrite = no
			invalid_pred_id(PredId),
			PredIds = [PredId | PredIds0],

			% We can just leave the method definition unchanged
			InstanceMethodDefn = InstanceMethodDefn0
		)
	;
		InstanceMethodDefn0 = name(InstanceMethodName0),
		PredOrFunc = predicate,
		init_markers(Markers),
		typecheck__resolve_pred_overloading(ModuleInfo, Markers,
			MethodCallArgTypes, MethodCallTVarSet,
			InstanceMethodName0, InstanceMethodName, PredId),
		PredIds = [PredId | PredIds0],
		InstanceMethodDefn = name(InstanceMethodName)
	;
		InstanceMethodDefn0 = clauses(_ItemList),
		%
		% XXX for methods defined using this syntax
		% it is a little tricky to write out the .opt files,
		% so for now I've just disabled intermodule optimization
		% for type class instance declarations using the new
		% syntax.
		%
		% This will force intermod__add_proc to return DoWrite = no
		invalid_pred_id(PredId),
		PredIds = [PredId | PredIds0],
		% We can just leave the method definition unchanged
		InstanceMethodDefn = InstanceMethodDefn0
	),
	InstanceMethod = instance_method(PredOrFunc, MethodName,
			InstanceMethodDefn, MethodArity, MethodContext).
			
	%
	% A `func(x/n) is y' method implementation can match an ordinary
	% function, a field access function or a constructor.
	% For now, if there are multiple possible matches, we don't write
	% the instance method.
	%
:- pred find_func_matching_instance_method(module_info::in, sym_name::in, 
		arity::in, tvarset::in, list(type)::in,
		maybe(pred_id)::out, sym_name::out) is semidet.

find_func_matching_instance_method(ModuleInfo, InstanceMethodName0,
		MethodArity, MethodCallTVarSet, MethodCallArgTypes,
		MaybePredId, InstanceMethodName) :-

	module_info_ctor_field_table(ModuleInfo, CtorFieldTable),
	(
		is_field_access_function_name(ModuleInfo, InstanceMethodName0,
			MethodArity, _, FieldName),
		map__search(CtorFieldTable, FieldName, FieldDefns)
	->
		TypeCtors0 = list__map(
			(func(FieldDefn) = TypeCtor :-
				FieldDefn = hlds_ctor_field_defn(_, _,
						TypeCtor, _, _)
			), FieldDefns)
	;
		TypeCtors0 = []
	),
	module_info_ctors(ModuleInfo, Ctors),
	(
		map__search(Ctors, cons(InstanceMethodName0, MethodArity),
			MatchingConstructors)
	->
		TypeCtors1 = list__map(
			(func(ConsDefn) = TypeCtor :-
				ConsDefn = hlds_cons_defn(_, _, _, TypeCtor, _)
			), MatchingConstructors)
	;
		TypeCtors1 = []
	),
	TypeCtors = list__append(TypeCtors0, TypeCtors1),

	module_info_get_predicate_table(ModuleInfo, PredicateTable),
	(
		predicate_table_search_func_sym_arity(PredicateTable,
			may_be_partially_qualified, InstanceMethodName0,
			MethodArity, PredIds),
		typecheck__find_matching_pred_id(PredIds, ModuleInfo,
			MethodCallTVarSet, MethodCallArgTypes,
			PredId, InstanceMethodFuncName)
	->
		TypeCtors = [],	
		MaybePredId = yes(PredId),
		InstanceMethodName = InstanceMethodFuncName
	;
		TypeCtors = [TheTypeCtor],
		MaybePredId = no,
		( TheTypeCtor = qualified(TypeModule, _) - _ ->
			unqualify_name(InstanceMethodName0, UnqualMethodName),
			InstanceMethodName =
				qualified(TypeModule, UnqualMethodName)
		;	
			error(
	"unqualified type_ctor in hlds_cons_defn or hlds_ctor_field_defn")
		)
	).

%-----------------------------------------------------------------------------%

:- pred intermod__gather_types(intermod_info::in, intermod_info::out) is det.

intermod__gather_types -->
	intermod_info_get_module_info(ModuleInfo),
	{ module_info_types(ModuleInfo, Types) },
	map__foldl(intermod__gather_types_2, Types).

:- pred intermod__gather_types_2(type_ctor::in,
	hlds_type_defn::in, intermod_info::in, intermod_info::out) is det.

intermod__gather_types_2(TypeCtor, TypeDefn0, Info0, Info) :-
	intermod_info_get_module_info(ModuleInfo, Info0, Info1),
	module_info_name(ModuleInfo, ModuleName),
	(
	    intermod__should_write_type(ModuleName, TypeCtor, TypeDefn0)
	->
	    hlds_data__get_type_defn_body(TypeDefn0, TypeBody0),
	    (
		TypeBody0 = du_type(Ctors, Tags, Enum, MaybeUserEqComp0,
			ReservedTag, IsSolverType, MaybeForeign0)
	    ->
		module_info_globals(ModuleInfo, Globals),
		globals__get_target(Globals, Target),

		%
		% Note that we don't resolve overloading for the definitions
		% which won't be used on this back-end, because their
		% unification and comparison predicates have not been
		% typechecked. They are only written to the `.opt' it
		% can be handy when building against a workspace for
		% the other definitions to be present (e.g. when testing
		% compiling a module to IL when the workspace was compiled
		% to C).
		%
		(
			MaybeForeign0 = yes(ForeignTypeBody0),
			have_foreign_type_for_backend(Target,
				ForeignTypeBody0, yes)
		->
			intermod__resolve_foreign_type_body_overloading(
				ModuleInfo, TypeCtor, ForeignTypeBody0,
				ForeignTypeBody, Info1, Info3),
			MaybeForeign = yes(ForeignTypeBody),
			MaybeUserEqComp = MaybeUserEqComp0	
		;
			intermod__resolve_unify_compare_overloading(ModuleInfo,
				TypeCtor, MaybeUserEqComp0, MaybeUserEqComp,
				Info1, Info3),
			MaybeForeign = MaybeForeign0
		),
		TypeBody = du_type(Ctors, Tags, Enum, MaybeUserEqComp,
				ReservedTag, IsSolverType, MaybeForeign),
		hlds_data__set_type_defn_body(TypeDefn0, TypeBody, TypeDefn)
	    ;	
		TypeBody0 = foreign_type(ForeignTypeBody0, IsSolverType)
	    ->
		intermod__resolve_foreign_type_body_overloading(ModuleInfo,
			TypeCtor, ForeignTypeBody0, ForeignTypeBody,
			Info1, Info3),
		TypeBody = foreign_type(ForeignTypeBody, IsSolverType),
		hlds_data__set_type_defn_body(TypeDefn0, TypeBody, TypeDefn)
	    ;
		Info3 = Info1,
		TypeDefn = TypeDefn0
	    ),
	    intermod_info_get_types(Types0, Info3, Info4),
	    intermod_info_set_types([TypeCtor - TypeDefn | Types0],
	        Info4, Info)
	;
	    Info = Info1
	).

:- pred intermod__resolve_foreign_type_body_overloading(module_info::in,
		type_ctor::in, foreign_type_body::in, foreign_type_body::out,
		intermod_info::in, intermod_info::out) is det.

intermod__resolve_foreign_type_body_overloading(ModuleInfo,
		TypeCtor, foreign_type_body(MaybeIL0, MaybeC0, MaybeJava0),
		foreign_type_body(MaybeIL, MaybeC, MaybeJava)) -->
	{ module_info_globals(ModuleInfo, Globals) },
	{ globals__get_target(Globals, Target) },

	%
	% Note that we don't resolve overloading for the foreign
	% definitions which won't be used on this back-end, because
	% their unification and comparison predicates have not been
	% typechecked.
	% They are only written to the `.opt' it can be handy when
	% building against a workspace for the other definitions to
	% be present (e.g. when testing compiling a module to IL when
	% the workspace was compiled to C).
	%
	( { Target = c ; Target = asm } ->
		intermod__resolve_foreign_type_body_overloading_2(ModuleInfo,
			TypeCtor, MaybeC0, MaybeC)
	;
		{ MaybeC = MaybeC0 }
	),
	( { Target = il } ->
		intermod__resolve_foreign_type_body_overloading_2(ModuleInfo,
			TypeCtor, MaybeIL0, MaybeIL)
	;
		{ MaybeIL = MaybeIL0 }
	),
	( { Target = java } ->
		intermod__resolve_foreign_type_body_overloading_2(ModuleInfo,
			TypeCtor, MaybeJava0, MaybeJava)
	;
		{ MaybeJava = MaybeJava0 }
	).

:- pred intermod__resolve_foreign_type_body_overloading_2(module_info::in,
		type_ctor::in, foreign_type_lang_body(T)::in,
		foreign_type_lang_body(T)::out, intermod_info::in,
		intermod_info::out) is det.

intermod__resolve_foreign_type_body_overloading_2(_, _, no, no, Info, Info).
intermod__resolve_foreign_type_body_overloading_2(ModuleInfo, TypeCtor,
		yes(Body - MaybeEqComp0), yes(Body - MaybeEqComp),
		Info0, Info) :-
	intermod__resolve_unify_compare_overloading(ModuleInfo, TypeCtor,
		MaybeEqComp0, MaybeEqComp, Info0, Info).

:- pred intermod__resolve_unify_compare_overloading(module_info::in,
	type_ctor::in, maybe(unify_compare)::in, maybe(unify_compare)::out,
	intermod_info::in, intermod_info::out) is det.

intermod__resolve_unify_compare_overloading(_, _, no, no, Info, Info).
intermod__resolve_unify_compare_overloading(_, _,
	yes(abstract_noncanonical_type), yes(abstract_noncanonical_type),
	Info, Info).
intermod__resolve_unify_compare_overloading(ModuleInfo, TypeCtor,
		yes(unify_compare(MaybeUserEq0, MaybeUserCompare0)),
		yes(unify_compare(MaybeUserEq, MaybeUserCompare)),
		Info0, Info) :-
	intermod__resolve_user_special_pred_overloading(ModuleInfo,
		unify, TypeCtor, MaybeUserEq0, MaybeUserEq, Info0, Info1),
	intermod__resolve_user_special_pred_overloading(ModuleInfo,
		compare, TypeCtor, MaybeUserCompare0, MaybeUserCompare,
		Info1, Info).

:- pred intermod__resolve_user_special_pred_overloading(module_info::in,
	special_pred_id::in, type_ctor::in, maybe(sym_name)::in,
	maybe(sym_name)::out, intermod_info::in, intermod_info::out) is det.

intermod__resolve_user_special_pred_overloading(_, _, _, no, no, Info, Info).
intermod__resolve_user_special_pred_overloading(ModuleInfo, SpecialId,
		TypeCtor, yes(Pred0), yes(Pred), Info0, Info) :-
	module_info_get_special_pred_map(ModuleInfo, SpecialPreds),
	map__lookup(SpecialPreds, SpecialId - TypeCtor, UnifyPredId),
	module_info_pred_info(ModuleInfo, UnifyPredId, UnifyPredInfo),
	pred_info_arg_types(UnifyPredInfo, TVarSet, _, ArgTypes),
	init_markers(Markers0),
	add_marker(Markers0, calls_are_fully_qualified, Markers),
	typecheck__resolve_pred_overloading(ModuleInfo, Markers, ArgTypes,
		TVarSet, Pred0, Pred, UserEqPredId),
	intermod__add_proc(UserEqPredId, _, Info0, Info).

:- pred intermod__should_write_type(module_name::in,
		type_ctor::in, hlds_type_defn::in) is semidet.

intermod__should_write_type(ModuleName, TypeCtor, TypeDefn) :-
	hlds_data__get_type_defn_status(TypeDefn, ImportStatus),
	TypeCtor = Name - _Arity,
	Name = qualified(ModuleName, _),
	import_status_to_write(ImportStatus).

%-----------------------------------------------------------------------------%
	% Output module imports, types, modes, insts and predicates

:- pred intermod__write_intermod_info(intermod_info::in,
				io__state::di, io__state::uo) is det.

intermod__write_intermod_info(IntermodInfo0) -->
	{ intermod_info_get_module_info(ModuleInfo,
		IntermodInfo0, IntermodInfo1) },
	{ module_info_name(ModuleInfo, ModuleName) },
	io__write_string(":- module "),
	mercury_output_bracketed_sym_name(ModuleName),
	io__write_string(".\n"),

	{ intermod_info_get_preds(Preds, IntermodInfo1, IntermodInfo2) },
	{ intermod_info_get_pred_decls(PredDecls,
		IntermodInfo2, IntermodInfo3) },
	{ intermod_info_get_instances(Instances,
		IntermodInfo3, IntermodInfo) },
	(
		%
		% If none of these item types need writing, nothing
		% else needs to be written.
		%
		{ set__empty(Preds) },
		{ set__empty(PredDecls) },
		{ Instances = [] },
		{ module_info_types(ModuleInfo, Types) },
		\+ {
			map__member(Types, _, TypeDefn),
			hlds_data__get_type_defn_status(TypeDefn, Status),
			( Status = abstract_exported
			; Status = exported_to_submodules
			)
		}
	->
		[]	
	;
		intermod__write_intermod_info_2(IntermodInfo)	
	).

:- pred intermod__write_intermod_info_2(intermod_info::in, io__state::di,
		io__state::uo) is det.

intermod__write_intermod_info_2(IntermodInfo) -->
	{ IntermodInfo = info(_, Preds0, PredDecls0, Instances, Types, _,
				ModuleInfo, WriteHeader, _, _) },
	{ set__to_sorted_list(Preds0, Preds) }, 
	{ set__to_sorted_list(PredDecls0, PredDecls) },


	{ module_info_get_imported_module_specifiers(ModuleInfo, Modules0) },
	{ set__to_sorted_list(Modules0, Modules) },
	( { Modules \= [] } ->
		% XXX this could be reduced to the set that is
		% actually needed by the items being written.
		io__write_string(":- use_module "),
		intermod__write_modules(Modules)
	;
		[]
	),

	intermod__write_types(Types),
	intermod__write_insts(ModuleInfo),
	intermod__write_modes(ModuleInfo),
	intermod__write_classes(ModuleInfo),
	intermod__write_instances(Instances),

	% Disable verbose dumping of clauses.
	globals__io_lookup_string_option(dump_hlds_options, VerboseDump),
	globals__io_set_option(dump_hlds_options, string("")),
	( { WriteHeader = yes } ->
		{ module_info_get_foreign_decl(ModuleInfo, RevForeignDecls) },
		{ module_info_get_pragma_exported_procs(ModuleInfo,
				PragmaExportedProcs) },
		{ module_info_get_foreign_import_module(ModuleInfo,
			RevForeignImports) },
		{ ForeignImports0 = list__reverse(RevForeignImports) },

		%
		% If this module contains `:- pragma export' or
		% `:- pragma foreign_decl' declarations,
		% they may be referred to by the C code we are writing
		% to the `.opt' file, so write the implicit
		% `:- pragma foreign_import_module("C", ModuleName).' 
		% to the `.opt' file.
		%
		% XXX Currently we only handle procedures
		% exported to C.
		{
			% Check that the  import could contain anything.
			( PragmaExportedProcs \= []
			; RevForeignDecls \= []
			)
		->
			module_info_name(ModuleInfo, ModuleName),
			ForeignImportThisModule = foreign_import_module(c,
				ModuleName, term__context_init),
			ForeignImports =
				[ForeignImportThisModule | ForeignImports0]
		;
			ForeignImports = ForeignImports0
		},

		list__foldl(
		    (pred(ForeignImport::in, di, uo) is det -->
		    	{ ForeignImport = foreign_import_module(Lang,
						Import, _) },
		    	mercury_output_pragma_foreign_import_module(Lang,
				Import)
		    ), ForeignImports)
	;
		[]
	),
	intermod__write_pred_decls(ModuleInfo, PredDecls),
	intermod__write_preds(ModuleInfo, Preds),
	globals__io_set_option(dump_hlds_options, string(VerboseDump)).

:- pred intermod__write_modules(list(module_name)::in,
			io__state::di, io__state::uo) is det.

intermod__write_modules([]) --> [].
intermod__write_modules([Module | Rest]) -->
	mercury_output_bracketed_sym_name(Module),
	(
		{ Rest = [] },
		io__write_string(".\n")
	;
		{ Rest = [_ | _] },
		io__write_string(", "),
		intermod__write_modules(Rest)
	).

:- pred intermod__write_types(assoc_list(type_ctor, hlds_type_defn)::in,
		io__state::di, io__state::uo) is det.

intermod__write_types(Types) -->
	list__foldl(intermod__write_type, Types).

:- pred intermod__write_type(pair(type_ctor, hlds_type_defn)::in,
		io__state::di, io__state::uo) is det.

intermod__write_type(TypeCtor - TypeDefn) -->
	{ hlds_data__get_type_defn_tvarset(TypeDefn, VarSet) },
	{ hlds_data__get_type_defn_tparams(TypeDefn, Args) },
	{ hlds_data__get_type_defn_body(TypeDefn, Body) },
	{ hlds_data__get_type_defn_context(TypeDefn, Context) },
	{ TypeCtor = Name - Arity },
	(
		{ Ctors = Body ^ du_type_ctors },
		{ IsSolverType = Body ^ du_type_is_solver_type },
		{ MaybeEqualityPred = Body ^ du_type_usereq },
		{ TypeBody = du_type(Ctors, IsSolverType, MaybeEqualityPred) }
	;
		{ Body = eqv_type(EqvType) },
		{ TypeBody = eqv_type(EqvType) }
	;
		{ Body = abstract_type(IsSolverType) },
		{ TypeBody = abstract_type(IsSolverType) }
	;
		{ Body = foreign_type(_, IsSolverType) },
		{ TypeBody = abstract_type(IsSolverType) }
	),
	mercury_output_item(type_defn(VarSet, Name, Args, TypeBody, true),
		Context),

	(
		{ Body = foreign_type(ForeignTypeBody, _)
		; Body ^ du_type_is_foreign_type = yes(ForeignTypeBody)
		},
		{ ForeignTypeBody = foreign_type_body(MaybeIL, MaybeC,
				MaybeJava) }
	->
		( { MaybeIL = yes(ILForeignType - ILUserEqComp) },
			mercury_output_item(pragma(
				foreign_type(il(ILForeignType), VarSet,
					Name, Args, ILUserEqComp)),
				Context)
		; { MaybeIL = no },
			[]
		),
		( { MaybeC = yes(CForeignType - CUserEqComp) },
			mercury_output_item(pragma(
				foreign_type(c(CForeignType), VarSet,
					Name, Args, CUserEqComp)),
				Context)
		; { MaybeC = no },
			[]
		),
		( { MaybeJava = yes(JavaForeignType - JavaUserEqComp) },
			mercury_output_item(pragma(
				foreign_type(
					java(JavaForeignType),
					VarSet, Name, Args, JavaUserEqComp)),
				Context)
		; { MaybeJava = no },
			[]
		)
	;
		[]
	),
	(
		{ ReservedTag = Body ^ du_type_reserved_tag },
		{ ReservedTag = yes }
	->
		mercury_output_item(pragma(reserve_tag(Name, Arity)),
			Context)
	;
		[]
	).

:- pred intermod__write_modes(module_info::in,
		io__state::di, io__state::uo) is det.

intermod__write_modes(ModuleInfo) -->
	{ module_info_name(ModuleInfo, ModuleName) },
	{ module_info_modes(ModuleInfo, Modes) },
	{ mode_table_get_mode_defns(Modes, ModeDefns) },
	map__foldl(intermod__write_mode(ModuleName), ModeDefns).

:- pred intermod__write_mode(module_name::in, mode_id::in, hlds_mode_defn::in,
		io__state::di, io__state::uo) is det.

intermod__write_mode(ModuleName, ModeId, ModeDefn) -->
	{ ModeId = SymName - _Arity },
	{ ModeDefn = hlds_mode_defn(Varset, Args, eqv_mode(Mode),
		Context, ImportStatus) },
	(
		{ SymName = qualified(ModuleName, _) },
		{ import_status_to_write(ImportStatus) }
	->
		mercury_output_item(
			mode_defn(Varset, SymName, Args, eqv_mode(Mode), true),
			Context)
	;
		[]
	).

:- pred intermod__write_insts(module_info::in,
		io__state::di, io__state::uo) is det.

intermod__write_insts(ModuleInfo) -->
	{ module_info_name(ModuleInfo, ModuleName) },
	{ module_info_insts(ModuleInfo, Insts) },
	{ inst_table_get_user_insts(Insts, UserInsts) },
	{ user_inst_table_get_inst_defns(UserInsts, InstDefns) },
	map__foldl(intermod__write_inst(ModuleName), InstDefns).

:- pred intermod__write_inst(module_name::in, inst_id::in, hlds_inst_defn::in, 
		io__state::di, io__state::uo) is det.

intermod__write_inst(ModuleName, InstId, InstDefn) -->
	{ InstId = SymName - _Arity },
	{ InstDefn = hlds_inst_defn(Varset, Args, Body,
		Context, ImportStatus) },
	(
		{ SymName = qualified(ModuleName, _) },
		{ import_status_to_write(ImportStatus) }
	->
		(
			{ Body = eqv_inst(Inst2) },
			{ InstBody = eqv_inst(Inst2) }
		;
			{ Body = abstract_inst },
			{ InstBody = abstract_inst }
		),
		mercury_output_item(
			inst_defn(Varset, SymName, Args, InstBody, true),
			Context)
	;
		[]
	).

:- pred intermod__write_classes(module_info::in,
		io__state::di, io__state::uo) is det.

intermod__write_classes(ModuleInfo) -->
	{ module_info_name(ModuleInfo, ModuleName) },
	{ module_info_classes(ModuleInfo, Classes) },
	map__foldl(intermod__write_class(ModuleName), Classes).

:- pred intermod__write_class(module_name::in, class_id::in,
		hlds_class_defn::in, io__state::di, io__state::uo) is det.

intermod__write_class(ModuleName, ClassId, ClassDefn) -->
	{ ClassDefn = hlds_class_defn(ImportStatus, Constraints,
			TVars, Interface, _HLDSClassInterface,
			TVarSet, Context) },
	{ ClassId = class_id(QualifiedClassName, _) },
	(
		{ QualifiedClassName = qualified(ModuleName, _) },
		{ import_status_to_write(ImportStatus) }
	->
		{ Item = typeclass(Constraints, QualifiedClassName, TVars,
				Interface, TVarSet) },
		mercury_output_item(Item, Context)
	;
		[]
	).

:- pred intermod__write_instances(assoc_list(class_id, hlds_instance_defn)::in,
		io__state::di, io__state::uo) is det.

intermod__write_instances(Instances) -->
	list__foldl(intermod__write_instance, Instances).

:- pred intermod__write_instance(pair(class_id, hlds_instance_defn)::in,
		io__state::di, io__state::uo) is det.

intermod__write_instance(ClassId - InstanceDefn) -->
	{ InstanceDefn = hlds_instance_defn(ModuleName, _, Context,
			Constraints, Types, Body, _, TVarSet, _) },
	{ ClassId = class_id(ClassName, _) },
	{ Item = instance(Constraints, ClassName, Types, Body, TVarSet,
		ModuleName) },
	mercury_output_item(Item, Context).

	% We need to write all the declarations for local predicates so
	% the procedure labels for the C code are calculated correctly.
:- pred intermod__write_pred_decls(module_info::in, list(pred_id)::in,
			io__state::di, io__state::uo) is det.

intermod__write_pred_decls(_, []) --> [].
intermod__write_pred_decls(ModuleInfo, [PredId | PredIds]) -->
	{ module_info_pred_info(ModuleInfo, PredId, PredInfo) },
	{ pred_info_module(PredInfo, Module) },
	{ pred_info_name(PredInfo, Name) },
	{ pred_info_arg_types(PredInfo, TVarSet, ExistQVars, ArgTypes) },
	{ pred_info_context(PredInfo, Context) },
	{ pred_info_get_purity(PredInfo, Purity) },
	{ pred_info_get_is_pred_or_func(PredInfo, PredOrFunc) },
	{ pred_info_get_class_context(PredInfo, ClassContext) },
	{ pred_info_get_goal_type(PredInfo, GoalType) },
	{
		GoalType = pragmas,
		% For foreign code goals we can't append variable numbers
		% to type variables in the predicate declaration
		% because the foreign code may contain references to
		% variables such as `TypeInfo_for_T' which will break
		% if `T' is written as `T_1' in the pred declaration.
		AppendVarNums = no
	;
		GoalType = clauses_and_pragmas,
		% Because pragmas may be present, we treat this case like
		% pragmas above.
		AppendVarNums = no
	;
		GoalType = clauses,
		AppendVarNums = yes
	;
		GoalType = promise(_),
		AppendVarNums = yes
	;
		GoalType = none,
		AppendVarNums = yes
	},
	(
		{ PredOrFunc = predicate },
		mercury_output_pred_type(TVarSet, ExistQVars,
			qualified(Module, Name), ArgTypes, no, Purity,
			ClassContext, Context, AppendVarNums)
	;
		{ PredOrFunc = function },
		{ pred_args_to_func_args(ArgTypes, FuncArgTypes, FuncRetType) },
		mercury_output_func_type(TVarSet, ExistQVars,
			qualified(Module, Name), FuncArgTypes,
			FuncRetType, no, Purity, ClassContext, Context,
			AppendVarNums)
	),
	{ pred_info_procedures(PredInfo, Procs) },
	{ pred_info_procids(PredInfo, ProcIds) },
		% Make sure the mode declarations go out in the same
		% order they came in, so that the all the modes get the
		% same proc_id in the importing modules.
	{ CompareProcId =
		 lambda([ProcId1::in, ProcId2::in, Result::out] is det, (
			proc_id_to_int(ProcId1, ProcInt1),
			proc_id_to_int(ProcId2, ProcInt2),
			compare(Result, ProcInt1, ProcInt2)
		)) },
	{ list__sort(CompareProcId, ProcIds, SortedProcIds) },
	intermod__write_pred_modes(Procs, qualified(Module, Name),
					PredOrFunc, SortedProcIds),
	intermod__write_pragmas(PredInfo),
	intermod__write_type_spec_pragmas(ModuleInfo, PredId),
	intermod__write_pred_decls(ModuleInfo, PredIds).

:- pred intermod__write_pred_modes(map(proc_id, proc_info)::in, 
		sym_name::in, pred_or_func::in, list(proc_id)::in,
		io__state::di, io__state::uo) is det.

intermod__write_pred_modes(_, _, _, []) --> [].
intermod__write_pred_modes(Procs, SymName, PredOrFunc, [ProcId | ProcIds]) -->
	{ map__lookup(Procs, ProcId, ProcInfo) },
	{ proc_info_maybe_declared_argmodes(ProcInfo, MaybeArgModes) },
	{ proc_info_declared_determinism(ProcInfo, MaybeDetism) },
	{ MaybeArgModes = yes(ArgModes0), MaybeDetism = yes(Detism0) ->
		ArgModes = ArgModes0,
		Detism = Detism0
	;
		error("intermod__write_pred_modes: attempt to write undeclared mode")
	},
	{ proc_info_context(ProcInfo, Context) },
	{ varset__init(Varset) },
	(
		{ PredOrFunc = function },
		{ pred_args_to_func_args(ArgModes, FuncArgModes, FuncRetMode) },
		mercury_output_func_mode_decl(Varset, SymName,
			FuncArgModes, FuncRetMode,
			yes(Detism), Context)
	;
		{ PredOrFunc = predicate },
		mercury_output_pred_mode_decl(Varset, SymName,
				ArgModes, yes(Detism), Context)
	),
	intermod__write_pred_modes(Procs, SymName, PredOrFunc, ProcIds).	

:- pred intermod__write_preds(module_info::in, list(pred_id)::in,
				io__state::di, io__state::uo) is det.

intermod__write_preds(_, []) --> [].
intermod__write_preds(ModuleInfo, [PredId | PredIds]) -->
	{ module_info_pred_info(ModuleInfo, PredId, PredInfo) },
	{ pred_info_module(PredInfo, Module) },
	{ pred_info_name(PredInfo, Name) },
	{ SymName = qualified(Module, Name) },
	{ pred_info_get_is_pred_or_func(PredInfo, PredOrFunc) },
	intermod__write_pragmas(PredInfo),
	% The type specialization pragmas for exported preds should
	% already be in the interface file.

	{ pred_info_clauses_info(PredInfo, ClausesInfo) },
	{ clauses_info_varset(ClausesInfo, VarSet) },
	{ clauses_info_headvars(ClausesInfo, HeadVars) },
	{ clauses_info_clauses(ClausesInfo, Clauses) },

	(
		{ pred_info_get_goal_type(PredInfo, promise(PromiseType)) }
	->
		(
			{ Clauses = [Clause] }
		->
			hlds_out__write_promise(PromiseType, 0, ModuleInfo, 
					PredId, VarSet, no, HeadVars, 
					PredOrFunc, Clause, no)
		;
			{ error("intermod__write_preds: assertion not a single clause.") }
		)
	;	
		list__foldl(intermod__write_clause(ModuleInfo, PredId, VarSet,
			HeadVars, PredOrFunc, SymName), Clauses)
	),
	intermod__write_preds(ModuleInfo, PredIds).

:- pred intermod__write_clause(module_info::in, pred_id::in, prog_varset::in,
		list(prog_var)::in, pred_or_func::in, sym_name::in, clause::in,
		io__state::di, io__state::uo) is det.

intermod__write_clause(ModuleInfo, PredId, VarSet, HeadVars,
		PredOrFunc, _SymName, Clause0) -->
	{ Clause0 = clause(_, _, mercury, _) },
	{ strip_headvar_unifications(HeadVars, Clause0,
		ClauseHeadVars, Clause) },
	% Variable numbers need to be appended for the case
	% where the added arguments for a DCG pred expression
	% are named the same as variables in the enclosing clause.
	{ AppendVarNums = yes },
	{ UseDeclaredModes = yes },
	{ MaybeVarTypes = no },
	hlds_out__write_clause(1, ModuleInfo, PredId, VarSet, AppendVarNums,
		ClauseHeadVars, PredOrFunc, Clause, UseDeclaredModes,
		MaybeVarTypes).

intermod__write_clause(ModuleInfo, PredId, VarSet, _HeadVars,
		PredOrFunc, SymName, Clause) -->
	{ Clause = clause(ProcIds, Goal, foreign_language(_), _) },
	{ module_info_pred_info(ModuleInfo, PredId, PredInfo) },
	{ pred_info_procedures(PredInfo, Procs) },
	(
		(
			% Pull the foreign code out of the goal.
			{ Goal = conj(Goals) - _ },
			{ list__filter(
				lambda([X::in] is semidet, (
				    X = foreign_proc(_,_,_,_,_,_,_) - _
				)),
				Goals, [ForeignCodeGoal]) },
			{ ForeignCodeGoal = foreign_proc(Attributes,
				_, _, Vars, Names, _, PragmaCode) - _ }
		;
			{ Goal = foreign_proc(Attributes,
				_, _, Vars, Names, _, PragmaCode) - _ }
		)
	->	
		list__foldl(intermod__write_foreign_clause(Procs,
			PredOrFunc, PragmaCode, Attributes, Vars, 
			VarSet, Names, SymName), ProcIds)
	;
		{ error("foreign_proc expected within this goal") }
	).


:- pred intermod__write_foreign_clause(proc_table::in, 
		pred_or_func::in, pragma_foreign_code_impl::in,
		pragma_foreign_proc_attributes::in, list(prog_var)::in,
		prog_varset::in, list(maybe(pair(string, mode)))::in,
		sym_name::in, proc_id::in, io__state::di, io__state::uo) is det.
intermod__write_foreign_clause(Procs, PredOrFunc, PragmaImpl,
		Attributes, Vars, VarSet0, Names, SymName, ProcId) -->
	{ map__lookup(Procs, ProcId, ProcInfo) },
	{ proc_info_maybe_declared_argmodes(ProcInfo, MaybeArgModes) },
	( { MaybeArgModes = yes(ArgModes) } ->
		{ get_pragma_foreign_code_vars(Vars, Names, VarSet0,
			ArgModes, VarSet, PragmaVars) },
		mercury_output_pragma_foreign_code(Attributes, SymName,
			PredOrFunc, PragmaVars, VarSet, PragmaImpl)
	;
		{ error("intermod__write_clause: no mode declaration") }
	).


	% Strip the `Headvar__n = Term' unifications from each clause,
	% except if the `Term' is a lambda expression.
	%
	% At least two problems occur if this is not done:
	% - in some cases where nested unique modes were accepted by
	% 	mode analysis, the extra aliasing added by the extra level
	%	of headvar unifications caused mode analysis to report
	% 	an error (ground expected unique), when analysing the
	% 	clauses read in from `.opt' files.
	% - only HeadVar unifications may be reordered with impure goals,
	%	so a mode error results for the second level of headvar
	% 	unifications added when the clauses are read in again from
	%	the `.opt' file. Clauses containing impure goals are not
	%	written to the `.opt' file for this reason.
:- pred strip_headvar_unifications(list(prog_var)::in,
		clause::in, list(prog_term)::out, clause::out) is det.

strip_headvar_unifications(HeadVars, clause(ProcIds, Goal0, Lang, Context),
		HeadTerms, clause(ProcIds, Goal, Lang, Context)) :-
	Goal0 = _ - GoalInfo0,
	goal_to_conj_list(Goal0, Goals0),
	map__init(HeadVarMap0),
	(
		strip_headvar_unifications_from_goal_list(Goals0, HeadVars,
			[], Goals, HeadVarMap0, HeadVarMap)
	->
		list__map(
		    (pred(HeadVar0::in, HeadTerm::out) is det :-
			( map__search(HeadVarMap, HeadVar0, HeadTerm0) ->
				HeadTerm = HeadTerm0
			;
				HeadTerm = term__variable(HeadVar0)
			)
		    ), HeadVars, HeadTerms),
		conj_list_to_goal(Goals, GoalInfo0, Goal)
	;
		term__var_list_to_term_list(HeadVars, HeadTerms),
		Goal = Goal0
	).

:- pred strip_headvar_unifications_from_goal_list(list(hlds_goal)::in,
		list(prog_var)::in, list(hlds_goal)::in, list(hlds_goal)::out,
		map(prog_var, prog_term)::in,
		map(prog_var, prog_term)::out) is semidet.

strip_headvar_unifications_from_goal_list([], _, RevGoals, Goals,
		HeadVarMap, HeadVarMap) :-
	list__reverse(RevGoals, Goals).
strip_headvar_unifications_from_goal_list([Goal | Goals0], HeadVars,
		RevGoals0, Goals, HeadVarMap0, HeadVarMap) :-
	(
		Goal = unify(LHSVar, RHS, _, _, _) - _,
		list__member(LHSVar, HeadVars),
		(
			RHS = var(RHSVar),
			RHSTerm = term__variable(RHSVar)
		;
			RHS = functor(ConsId, _, Args),
			term__context_init(Context),
			(
				ConsId = int_const(Int),
				RHSTerm = term__functor(term__integer(Int),
						[], Context)
			;
				ConsId = float_const(Float),
				RHSTerm = term__functor(term__float(Float),
						[], Context)
			;
				ConsId = string_const(String),
				RHSTerm = term__functor(term__string(String),
						[], Context)
			;
				ConsId = cons(SymName, _),
				term__var_list_to_term_list(Args, ArgTerms),
				construct_qualified_term(SymName, ArgTerms,
					RHSTerm)
			)
		)
	->
		% Don't strip the headvar unifications if one of the
		% headvars appears twice. This should probably never happen.
		map__insert(HeadVarMap0, LHSVar, RHSTerm, HeadVarMap1),
		RevGoals1 = RevGoals0
	;
		HeadVarMap1 = HeadVarMap0,
		RevGoals1 = [Goal | RevGoals0]
	),
	strip_headvar_unifications_from_goal_list(Goals0, HeadVars,
		RevGoals1, Goals, HeadVarMap1, HeadVarMap).

:- pred intermod__write_pragmas(pred_info::in,
		io__state::di, io__state::uo) is det.

intermod__write_pragmas(PredInfo) -->
	{ pred_info_module(PredInfo, Module) },
	{ pred_info_name(PredInfo, Name) },
	{ pred_info_arity(PredInfo, Arity) },
	{ SymName = qualified(Module, Name) },
	{ pred_info_get_markers(PredInfo, Markers) },
	{ markers_to_marker_list(Markers, MarkerList) },
	{ pred_info_get_is_pred_or_func(PredInfo, PredOrFunc) },
	intermod__write_pragmas(SymName, Arity, MarkerList, PredOrFunc).

:- pred intermod__write_pragmas(sym_name::in, int::in, list(marker)::in,
		pred_or_func::in, io__state::di, io__state::uo) is det.

intermod__write_pragmas(_, _, [], _) --> [].
intermod__write_pragmas(SymName, Arity, [Marker | Markers], PredOrFunc) -->
	{ intermod__should_output_marker(Marker, ShouldOutput) },
	( { ShouldOutput = yes } ->
		{ hlds_out__marker_name(Marker, Name) },
		mercury_output_pragma_decl(SymName, Arity, PredOrFunc, Name)
	;
		[]
	),
	intermod__write_pragmas(SymName, Arity, Markers, PredOrFunc).

:- pred intermod__write_type_spec_pragmas(module_info::in, pred_id::in,
		io__state::di, io__state::uo) is det.

intermod__write_type_spec_pragmas(ModuleInfo, PredId) -->
	{ module_info_type_spec_info(ModuleInfo,
		type_spec_info(_, _, _, PragmaMap)) },
	( { multi_map__search(PragmaMap, PredId, TypeSpecPragmas) } ->
		list__foldl(
		    ( pred(Pragma::in, di, uo) is det -->
			( { Pragma = type_spec(_, _, _, _, _, _, _, _) } ->
				{ AppendVarnums = yes },
				mercury_output_pragma_type_spec(Pragma,
					AppendVarnums)
			;
				{ error("intermod__write_type_spec_pragmas") }
			)
		    ), TypeSpecPragmas)
	;
		[]
	).

	% Is a pragma declaration required in the `.opt' file for
	% a predicate with the given marker.
:- pred intermod__should_output_marker(marker::in, bool::out) is det.

intermod__should_output_marker(stub, no).
	% Since the inferred declarations are output, these
	% don't need to be done in the importing module.
intermod__should_output_marker(infer_type, no).
intermod__should_output_marker(infer_modes, no).
	% Purity is output as part of the pred/func decl.
intermod__should_output_marker((impure), no).
intermod__should_output_marker((semipure), no).
	% There is no pragma required for generated class methods.
intermod__should_output_marker(class_method, no).
intermod__should_output_marker(class_instance_method, no).
intermod__should_output_marker(named_class_instance_method, no).
	% The warning for calls to local obsolete predicates should appear
	% once in the defining module, not in importing modules.
intermod__should_output_marker(obsolete, no).
intermod__should_output_marker(inline, yes).
intermod__should_output_marker(no_inline, yes).
intermod__should_output_marker(dnf, yes).
intermod__should_output_marker(aditi, yes).
intermod__should_output_marker(base_relation, yes).
intermod__should_output_marker(aditi_memo, yes).
intermod__should_output_marker(aditi_no_memo, yes).
intermod__should_output_marker(naive, yes).
intermod__should_output_marker(psn, yes).
intermod__should_output_marker(supp_magic, yes).
intermod__should_output_marker(context, yes).
intermod__should_output_marker(promised_pure, yes).
intermod__should_output_marker(promised_semipure, yes).
intermod__should_output_marker(terminates, yes).
intermod__should_output_marker(does_not_terminate, yes).
	% Termination should only be checked in the defining module.
intermod__should_output_marker(check_termination, no).
intermod__should_output_marker(generate_inline, _) :-
	% This marker should only occur after the magic sets transformation.
	error("intermod__should_output_marker: generate_inline").
intermod__should_output_marker(calls_are_fully_qualified, no).
intermod__should_output_marker(not_accessible_by_unqualifed_name, no).
intermod__should_output_marker(not_accessible_by_partially_qualified_names, no).

:- pred get_pragma_foreign_code_vars(list(prog_var)::in,
		list(maybe(pair(string, mode)))::in, prog_varset::in,
		list(mode)::in, prog_varset::out, list(pragma_var)::out) is det.

get_pragma_foreign_code_vars(HeadVars, VarNames, VarSet0, ArgModes,
		VarSet, PragmaVars) :- 
	(
		HeadVars = [Var | Vars],
		VarNames = [Maybe_NameAndMode | Names],
		ArgModes = [Mode | Modes]
	->
		(
			Maybe_NameAndMode = no,
			Name = "_"
		;
			Maybe_NameAndMode = yes(Name - _Mode2)
		),
		PragmaVar = pragma_var(Var, Name, Mode),
		varset__name_var(VarSet0, Var, Name, VarSet1),
		get_pragma_foreign_code_vars(Vars, Names, VarSet1, Modes,
			VarSet, PragmaVars1),
		PragmaVars = [PragmaVar | PragmaVars1] 
	;
		HeadVars = [],
		VarNames = [],
		ArgModes = []
	->
		PragmaVars = [],
		VarSet = VarSet0
	;
		error("intermod:get_pragma_foreign_code_vars")
	).

%-----------------------------------------------------------------------------%
	% Access predicates.

:- pred intermod_info_get_modules(set(module_name)::out, intermod_info::in,
			intermod_info::out) is det.
:- pred intermod_info_get_preds(set(pred_id)::out, 
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_get_pred_decls(set(pred_id)::out, 
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_get_instances(
			assoc_list(class_id, hlds_instance_defn)::out, 
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_get_types(assoc_list(type_ctor, hlds_type_defn)::out, 
			intermod_info::in, intermod_info::out) is det.
%:- pred intermod_info_get_insts(set(inst_id)::out, 
%			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_get_module_info(module_info::out,
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_get_write_foreign_header(bool::out,
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_get_var_types(map(prog_var, type)::out,
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_get_tvarset(tvarset::out, intermod_info::in,
			intermod_info::out) is det.

intermod_info_get_modules(Modules)	--> =(info(Modules,_,_,_,_,_,_,_,_,_)). 
intermod_info_get_preds(Procs)		--> =(info(_,Procs,_,_,_,_,_,_,_,_)).
intermod_info_get_pred_decls(ProcDecls) -->
					=(info(_,_,ProcDecls,_,_,_,_,_,_,_)).
intermod_info_get_instances(Instances) -->
		=(info(_,_,_,Instances,_,_,_,_,_,_)).
intermod_info_get_types(Types)		--> =(info(_,_,_,_,Types,_,_,_,_,_)).
%intermod_info_get_modes(Modes)		--> =(info(_,_,_,_,Modes,_,_,_,_,_)).
%intermod_info_get_insts(Insts)		--> =(info(_,_,_,_,_,Insts,_,_,_,_)).
intermod_info_get_module_info(Module)	--> =(info(_,_,_,_,_,_,Module,_,_,_)).
intermod_info_get_write_foreign_header(Write)	--> 
					    =(info(_,_,_,_,_,_,_,Write,_,_)).
intermod_info_get_var_types(VarTypes)	--> =(info(_,_,_,_,_,_,_,_,VarTypes,_)).
intermod_info_get_tvarset(TVarSet)	--> =(info(_,_,_,_,_,_,_,_,_,TVarSet)).

:- pred intermod_info_set_modules(set(module_name)::in,
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_set_preds(set(pred_id)::in, 
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_set_pred_decls(set(pred_id)::in, 
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_set_instances(
			assoc_list(class_id, hlds_instance_defn)::in, 
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_set_types(assoc_list(type_ctor, hlds_type_defn)::in, 
			intermod_info::in, intermod_info::out) is det.
%:- pred intermod_info_set_insts(set(inst_id)::in, 
%			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_set_module_info(module_info::in,
			intermod_info::in, intermod_info::out) is det.
:- pred intermod_info_set_write_header(intermod_info::in,
			intermod_info::out) is det.
:- pred intermod_info_set_var_types(map(prog_var, type)::in, intermod_info::in, 
			intermod_info::out) is det.
:- pred intermod_info_set_tvarset(tvarset::in, intermod_info::in,
			intermod_info::out) is det.

intermod_info_set_modules(Modules, info(_,B,C,D,E,F,G,H,I,J),
				info(Modules, B,C,D,E,F,G,H,I,J)).

intermod_info_set_preds(Procs, info(A,_,C,D,E,F,G,H,I,J),
				info(A, Procs, C,D,E,F,G,H,I,J)).

intermod_info_set_pred_decls(ProcDecls, info(A,B,_,D,E,F,G,H,I,J),
				info(A,B, ProcDecls, D,E,F,G,H,I,J)).

intermod_info_set_instances(Instances, info(A,B,C,_,E,F,G,H,I,J),
				info(A,B,C, Instances, E,F,G,H,I,J)).

intermod_info_set_types(Types, info(A,B,C,D, _, F,G,H,I,J),
				info(A,B,C,D, Types, F,G,H,I,J)).

%intermod_info_set_insts(Insts, info(A,B,C,D,E,_,G,H,I,J),
%				info(A,B,C,D,E, Insts, G,H,I,J)).

intermod_info_set_module_info(ModuleInfo, info(A,B,C,D,E,F,_,H,I,J),
				info(A,B,C,D,E,F, ModuleInfo, H,I,J)).

intermod_info_set_write_header(info(A,B,C,D,E,F,G,_,I,J),
				 info(A,B,C,D,E,F,G, yes,I,J)).

intermod_info_set_var_types(VarTypes, info(A,B,C,D,E,F,G,H,_,J),
				info(A,B,C,D,E,F,G,H,VarTypes,J)).

intermod_info_set_tvarset(TVarSet, info(A,B,C,D,E,F,G,H,I,_),
				info(A,B,C,D,E,F,G,H,I, TVarSet)).

%-----------------------------------------------------------------------------%

	% Make sure the labels of local preds needed by predicates in 
	% the .opt file are exported, and inhibit dead proc elimination
	% on those preds.
intermod__adjust_pred_import_status(Module0, Module, IO0, IO) :-
	globals__io_lookup_bool_option(very_verbose, VVerbose, IO0, IO1),
	maybe_write_string(VVerbose, 
		"% Adjusting import status of predicates in the `.opt' file...",
		IO1, IO2),

	init_intermod_info(Module0, Info0),
	module_info_predids(Module0, PredIds),
	module_info_globals(Module0, Globals),
	globals__lookup_int_option(Globals, intermod_inline_simple_threshold, 
			Threshold),
	globals__lookup_bool_option(Globals, deforestation, Deforestation),
	globals__lookup_int_option(Globals, higher_order_size_limit,
		HigherOrderSizeLimit),
	intermod__gather_preds(PredIds, yes, Threshold, HigherOrderSizeLimit,
		Deforestation, Info0, Info1),
	intermod__gather_instances(Info1, Info2),
	intermod__gather_types(Info2, Info),
	do_adjust_pred_import_status(Info, Module0, Module),
	maybe_write_string(VVerbose, " done\n", IO2, IO).

:- pred do_adjust_pred_import_status(intermod_info::in,
		module_info::in, module_info::out) is det.

do_adjust_pred_import_status(Info, ModuleInfo0, ModuleInfo) :-
	intermod_info_get_pred_decls(PredDecls0, Info, _),
	set__to_sorted_list(PredDecls0, PredDecls),
	set_list_of_preds_exported(PredDecls, ModuleInfo0, ModuleInfo1),
	adjust_type_status(ModuleInfo1, ModuleInfo2),
	adjust_class_status(ModuleInfo2, ModuleInfo3),
	adjust_instance_status(ModuleInfo3, ModuleInfo).

:- pred adjust_type_status(module_info::in, module_info::out) is det.

adjust_type_status(ModuleInfo0, ModuleInfo) :-
	module_info_types(ModuleInfo0, Types0),
	map__to_assoc_list(Types0, TypesAL0),
	list__map_foldl(adjust_type_status_2, TypesAL0, TypesAL,
		ModuleInfo0, ModuleInfo1),
	map__from_assoc_list(TypesAL, Types),
	module_info_set_types(ModuleInfo1, Types, ModuleInfo).

:- pred adjust_type_status_2(pair(type_ctor, hlds_type_defn)::in,
		pair(type_ctor, hlds_type_defn)::out,
		module_info::in, module_info::out) is det.

adjust_type_status_2(TypeCtor - TypeDefn0, TypeCtor - TypeDefn,
		ModuleInfo0, ModuleInfo) :-
	module_info_name(ModuleInfo0, ModuleName),
	( intermod__should_write_type(ModuleName, TypeCtor, TypeDefn0) ->
		hlds_data__set_type_defn_status(TypeDefn0, exported, TypeDefn),
		fixup_special_preds(TypeCtor, ModuleInfo0, ModuleInfo)
	;
		ModuleInfo = ModuleInfo0,
		TypeDefn = TypeDefn0
	).

:- pred fixup_special_preds((type_ctor)::in,
		module_info::in, module_info::out) is det.

fixup_special_preds(TypeCtor, ModuleInfo0, ModuleInfo) :-
	special_pred_list(SpecialPredList),
	module_info_get_special_pred_map(ModuleInfo0, SpecPredMap),
	list__filter_map((pred(SpecPredId::in, PredId::out) is semidet :-
			map__search(SpecPredMap, SpecPredId - TypeCtor, PredId)
		), SpecialPredList, PredIds),
	set_list_of_preds_exported(PredIds, ModuleInfo0, ModuleInfo).

:- pred adjust_class_status(module_info::in, module_info::out) is det.

adjust_class_status(ModuleInfo0, ModuleInfo) :-
	module_info_classes(ModuleInfo0, Classes0),
	map__to_assoc_list(Classes0, ClassAL0),
	list__map_foldl(adjust_class_status_2, ClassAL0, ClassAL,
		ModuleInfo0, ModuleInfo1),
	map__from_assoc_list(ClassAL, Classes),
	module_info_set_classes(ModuleInfo1, Classes, ModuleInfo).

:- pred adjust_class_status_2(pair(class_id, hlds_class_defn)::in,
		pair(class_id, hlds_class_defn)::out,
		module_info::in, module_info::out) is det.

adjust_class_status_2(ClassId - ClassDefn0, ClassId - ClassDefn,
			ModuleInfo0, ModuleInfo) :-
	(
		ClassDefn0 = hlds_class_defn(Status0, Constraints, TVars,
				Interface, HLDSClassInterface,
				TVarSet, Context),	
		import_status_to_write(Status0)
	->
		ClassDefn = hlds_class_defn(exported, Constraints, TVars,
				Interface, HLDSClassInterface,
				TVarSet, Context),
		class_procs_to_pred_ids(HLDSClassInterface, PredIds),
		set_list_of_preds_exported(PredIds, ModuleInfo0, ModuleInfo)
	;
		ClassDefn = ClassDefn0,
		ModuleInfo = ModuleInfo0
	).

:- pred class_procs_to_pred_ids(list(hlds_class_proc)::in,
		list(pred_id)::out) is det.

class_procs_to_pred_ids(ClassProcs, PredIds) :-
	list__map(
		(pred(ClassProc::in, PredId::out) is det :-
			ClassProc = hlds_class_proc(PredId, _)
		),
		ClassProcs, PredIds0),
	list__sort_and_remove_dups(PredIds0, PredIds).

:- pred adjust_instance_status(module_info::in, module_info::out) is det.

adjust_instance_status(ModuleInfo0, ModuleInfo) :-
	module_info_instances(ModuleInfo0, Instances0),
	map__to_assoc_list(Instances0, InstanceAL0),
	list__map_foldl(adjust_instance_status_2, InstanceAL0, InstanceAL,
		ModuleInfo0, ModuleInfo1),
	map__from_assoc_list(InstanceAL, Instances),
	module_info_set_instances(ModuleInfo1, Instances, ModuleInfo).

:- pred adjust_instance_status_2(pair(class_id, list(hlds_instance_defn))::in,
		pair(class_id, list(hlds_instance_defn))::out,
		module_info::in, module_info::out) is det.

adjust_instance_status_2(ClassId - InstanceList0, ClassId - InstanceList,
		ModuleInfo0, ModuleInfo) :-
	list__map_foldl(adjust_instance_status_3, InstanceList0, InstanceList,
		ModuleInfo0, ModuleInfo).	

:- pred adjust_instance_status_3(hlds_instance_defn::in,
	hlds_instance_defn::out, module_info::in, module_info::out) is det.

adjust_instance_status_3(Instance0, Instance, ModuleInfo0, ModuleInfo) :-
	Instance0 = hlds_instance_defn(InstanceModule, Status0, Context,
			Constraints, Types, Body, HLDSClassInterface,
			TVarSet, ConstraintProofs),
	(
		import_status_to_write(Status0)
	->
		Instance = hlds_instance_defn(InstanceModule, exported,
			Context, Constraints, Types, Body, HLDSClassInterface,
			TVarSet, ConstraintProofs),
		( HLDSClassInterface = yes(ClassInterface) ->
			class_procs_to_pred_ids(ClassInterface, PredIds),
			set_list_of_preds_exported(PredIds,
				ModuleInfo0, ModuleInfo)
		;
			% This can happen if an instance has multiple
			% declarations, one of which is abstract.
			ModuleInfo = ModuleInfo0
		)
	;
		ModuleInfo = ModuleInfo0,
		Instance = Instance0
	).

:- pred set_list_of_preds_exported(list(pred_id)::in, module_info::in,
		module_info::out) is det.

set_list_of_preds_exported(PredIds, ModuleInfo0, ModuleInfo) :-
	module_info_preds(ModuleInfo0, Preds0),
	set_list_of_preds_exported_2(PredIds, Preds0, Preds),
	module_info_set_preds(ModuleInfo0, Preds, ModuleInfo).

:- pred set_list_of_preds_exported_2(list(pred_id)::in, pred_table::in,
					pred_table::out) is det.

set_list_of_preds_exported_2([], Preds, Preds).
set_list_of_preds_exported_2([PredId | PredIds], Preds0, Preds) :-
	map__lookup(Preds0, PredId, PredInfo0),
	(
		pred_info_import_status(PredInfo0, Status),
		import_status_to_write(Status)
	->	
		(
			pred_info_get_maybe_special_pred(PredInfo0,
				MaybeSpecial),
			MaybeSpecial = yes(unify - _)
		->
			NewStatus = pseudo_exported
		;
			Status = external(implementation)
		->
			NewStatus = external(interface)
		;
			NewStatus = opt_exported
		),
		pred_info_set_import_status(PredInfo0, NewStatus, PredInfo),
		map__det_update(Preds0, PredId, PredInfo, Preds1)
	;
		Preds1 = Preds0
	),
	set_list_of_preds_exported_2(PredIds, Preds1, Preds).

	% Should a declaration with the given status be written
	% to the `.opt' file.
:- pred import_status_to_write(import_status::in) is semidet.

import_status_to_write(Status) :-
	import_status_to_write(Status) = yes.

:- func import_status_to_write(import_status) = bool.

import_status_to_write(external(interface)) = no.
import_status_to_write(external(implementation)) = yes.
import_status_to_write(imported(_)) = no.
import_status_to_write(abstract_imported) = no.
import_status_to_write(pseudo_imported) = no.
import_status_to_write(opt_imported) = no.
import_status_to_write(exported) = no.
import_status_to_write(opt_exported) = yes.
import_status_to_write(abstract_exported) = yes.
import_status_to_write(pseudo_exported) = no.
import_status_to_write(exported_to_submodules) = yes.
import_status_to_write(local) = yes.

%-----------------------------------------------------------------------------%
	% Read in and process the optimization interfaces.

intermod__grab_optfiles(Module0, Module, FoundError) -->

		%
		% Read in the .opt files for imported and ancestor modules.
		%
	{ ModuleName = Module0 ^ module_name },
	{ Ancestors0 = Module0 ^ parent_deps },
	{ InterfaceDeps0 = Module0 ^ int_deps },
	{ ImplementationDeps0 = Module0 ^ impl_deps },
	{ OptFiles = list__sort_and_remove_dups(list__condense(
		[Ancestors0, InterfaceDeps0, ImplementationDeps0])) },
	globals__io_lookup_bool_option(read_opt_files_transitively,
		Transitive),
	{ ModulesProcessed = set__insert(set__sorted_list_to_set(OptFiles),
				ModuleName) },
	read_optimization_interfaces(Transitive, ModuleName, OptFiles,
		ModulesProcessed, [], OptItems, no, OptError),

		%
		% Append the items to the current item list, using
		% a `opt_imported' psuedo-declaration to let
		% make_hlds know the opt_imported stuff is coming.
		%
	{ module_imports_get_items(Module0, Items0) },
	{ make_pseudo_decl(opt_imported, OptImportedDecl) },
	{ list__append(Items0, [OptImportedDecl | OptItems], Items1) },
	{ module_imports_set_items(Module0, Items1, Module1) },

		%
		% Get the :- pragma unused_args(...) declarations created
		% when writing the .opt file for the current module. These
		% are needed because we can probably remove more arguments
		% with intermod_unused_args, but the interface for other
		% modules must remain the same.
		%
	globals__io_lookup_bool_option(intermod_unused_args, UnusedArgs),
	( { UnusedArgs = yes } ->
		read_optimization_interfaces(no, ModuleName, [ModuleName],
				set__init, [], LocalItems, no, UAError),
		{ IsPragmaUnusedArgs = lambda([Item::in] is semidet, (
					Item = pragma(PragmaType) - _,
					PragmaType = unused_args(_,_,_,_,_)
				)) },
		{ list__filter(IsPragmaUnusedArgs, LocalItems, PragmaItems) },

		{ module_imports_get_items(Module1, Items2) },
		{ list__append(Items2, PragmaItems, Items) },
		{ module_imports_set_items(Module1, Items, Module2) }
	;
		{ Module2 = Module1 },
		{ UAError = no }
	),

		%
		% Read .int0 files required by the `.opt' files.
		%
	{ Int0Files = list__delete_all(
			list__condense(list__map(get_ancestors, OptFiles)),
			ModuleName) },
	process_module_private_interfaces(ReadModules, Int0Files,
			[], AncestorImports1, [], AncestorImports2,
			Module2, Module3),

		%
		% Figure out which .int files are needed by the .opt files
		%
	{ get_dependencies(OptItems, NewImportDeps0, NewUseDeps0) },
	globals__io_get_globals(Globals),
	{ get_implicit_dependencies(OptItems, Globals,
		NewImplicitImportDeps0, NewImplicitUseDeps0) },
	{ NewDeps = list__sort_and_remove_dups(list__condense(
		[NewImportDeps0, NewUseDeps0,
		NewImplicitImportDeps0, NewImplicitUseDeps0,
		AncestorImports1, AncestorImports2])) },

		%
		% Read in the .int, and .int2 files needed by the .opt files.
		%
	{ map__init(ReadModules) },
	process_module_long_interfaces(ReadModules, must_be_qualified, NewDeps,
			".int", [], NewIndirectDeps, Module3, Module4),
	process_module_short_interfaces_transitively(ReadModules,
			NewIndirectDeps, ".int2", Module4, Module),

		%
		% Figure out whether anything went wrong
		%
	{ module_imports_get_error(Module, FoundError0) },
	{
		( FoundError0 \= no_module_errors
		; OptError = yes
		; UAError = yes
		)
	->
		FoundError = yes
	;
		FoundError = no
	}.

:- pred read_optimization_interfaces(bool::in, module_name::in,
	list(module_name)::in, set(module_name)::in,
	item_list::in, item_list::out, bool::in, bool::out,
	io__state::di, io__state::uo) is det.

read_optimization_interfaces(_, _, [], _, Items, Items, Error, Error) --> [].
read_optimization_interfaces(Transitive, ModuleName,
		[ModuleToRead | ModulesToRead], ModulesProcessed0,
		Items0, Items, Error0, Error) -->
	globals__io_lookup_bool_option(very_verbose, VeryVerbose),
	maybe_write_string(VeryVerbose,
			"% Reading optimization interface for module"),
	maybe_write_string(VeryVerbose, " `"),
	{ prog_out__sym_name_to_string(ModuleToRead, ModuleToReadString) },
	maybe_write_string(VeryVerbose, ModuleToReadString),
	maybe_write_string(VeryVerbose, "'...\n"),
	maybe_flush_output(VeryVerbose),

	module_name_to_search_file_name(ModuleToRead, ".opt", FileName),
	prog_io__read_opt_file(FileName, ModuleToRead,
			ModuleError, Messages, OptItems),
	update_error_status(opt, FileName, ModuleError, Messages,
			Error0, Error1),
	{ Items1 = Items0 ++ OptItems },
	maybe_write_string(VeryVerbose, "% done.\n"),

	globals__io_get_globals(Globals),
	{ Transitive = yes ->
		get_dependencies(OptItems, NewImportDeps0, NewUseDeps0),
		get_implicit_dependencies(OptItems, Globals,
			NewImplicitImportDeps0, NewImplicitUseDeps0),
		NewDeps0 = list__condense([NewImportDeps0,
			NewUseDeps0, NewImplicitImportDeps0,
			NewImplicitUseDeps0]),
		set__list_to_set(NewDeps0, NewDepsSet0),
		set__difference(NewDepsSet0, ModulesProcessed0, NewDepsSet),
		set__union(ModulesProcessed0, NewDepsSet, ModulesProcessed),
		set__to_sorted_list(NewDepsSet, NewDeps)
	;
		ModulesProcessed = ModulesProcessed0,
		NewDeps = []
	},
	read_optimization_interfaces(Transitive, ModuleName,
		NewDeps ++ ModulesToRead, ModulesProcessed,
		Items1, Items, Error1, Error).

update_error_status(FileType, FileName, ModuleError, Messages,
		Error0, Error1) -->
	(
		{ ModuleError = no_module_errors },
		{ Error1 = Error0 }
	;
		{ ModuleError = some_module_errors },
		prog_out__write_messages(Messages),
		{ Error1 = yes }
	;
		{ ModuleError = fatal_module_errors },
		{
			FileType = opt,
			WarningOption = warn_missing_opt_files
		;
			FileType = trans_opt,
			WarningOption = warn_missing_trans_opt_files
		},
		globals__io_lookup_bool_option(WarningOption, DoWarn),
		( { DoWarn = yes } ->
			io__write_string("Warning: cannot open `"),
			io__write_string(FileName),
			io__write_string("'.\n"),
			globals__io_lookup_bool_option(halt_at_warn,
					HaltAtWarn),
			{ HaltAtWarn = yes ->
				Error1 = yes
			;
				Error1 = Error0
			}
		;
			{ Error1 = Error0 }	
		)
	).

%-----------------------------------------------------------------------------%
