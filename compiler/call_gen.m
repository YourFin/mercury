%---------------------------------------------------------------------------%
% Copyright (C) 1994-1999 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% file: call_gen.m
%
% main author: conway.
%
% This module provides predicates for generating procedure calls,
% including calls to higher-order pred variables.
%
%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- module call_gen.

:- interface.

:- import_module prog_data, hlds_pred, hlds_goal, llds, code_info.
:- import_module list, set, assoc_list.

:- pred call_gen__generate_generic_call(code_model, generic_call,
			list(prog_var), list(mode), determinism,
			hlds_goal_info, code_tree, code_info, code_info).
:- mode call_gen__generate_generic_call(in, in, in, in, in, in,
			out, in, out) is det.

:- pred call_gen__generate_call(code_model, pred_id, proc_id, list(prog_var),
			hlds_goal_info, code_tree, code_info, code_info).
:- mode call_gen__generate_call(in, in, in, in, in, out, in, out) is det.

:- pred call_gen__generate_builtin(code_model, pred_id, proc_id, list(prog_var),
			code_tree, code_info, code_info).
:- mode call_gen__generate_builtin(in, in, in, in, out, in, out) is det.

:- pred call_gen__partition_args(assoc_list(prog_var, arg_info),
						list(prog_var), list(prog_var)).
:- mode call_gen__partition_args(in, out, out) is det.

:- pred call_gen__input_arg_locs(assoc_list(prog_var, arg_info), 
				assoc_list(prog_var, arg_loc)).
:- mode call_gen__input_arg_locs(in, out) is det.

:- pred call_gen__output_arg_locs(assoc_list(prog_var, arg_info), 
				assoc_list(prog_var, arg_loc)).
:- mode call_gen__output_arg_locs(in, out) is det.

:- pred call_gen__save_variables(set(prog_var), code_tree,
						code_info, code_info).
:- mode call_gen__save_variables(in, out, in, out) is det.

%---------------------------------------------------------------------------%

:- implementation.

:- import_module hlds_module, hlds_data, code_util, rl.
:- import_module arg_info, type_util, mode_util, unify_proc, instmap.
:- import_module trace, globals, options.
:- import_module std_util, bool, int, tree, map.
:- import_module varset, require, string.

%---------------------------------------------------------------------------%

call_gen__generate_call(CodeModel, PredId, ModeId, Arguments, GoalInfo, Code)
		-->

		% Find out which arguments are input and which are output.
	code_info__get_pred_proc_arginfo(PredId, ModeId, ArgInfo),
	{ assoc_list__from_corresponding_lists(Arguments, ArgInfo, ArgsInfos) },

		% Save the known variables on the stack, except those
		% generated by this call.
	{ call_gen__select_out_args(ArgsInfos, OutArgs) },
	call_gen__save_variables(OutArgs, SaveCode),

		% Save possibly unknown variables on the stack as well
		% if they may be needed on backtracking, and figure out the
		% call model.
	call_gen__prepare_for_call(CodeModel, FlushCode, CallModel),

		% Move the input arguments to their registers.
	code_info__setup_call(ArgsInfos, caller, SetupCode),

	trace__prepare_for_call(TraceCode),

		% Figure out what locations are live at the call point,
		% for use by the value numbering optimization.
	{ call_gen__input_args(ArgInfo, InputArguments) },
	call_gen__generate_call_vn_livevals(InputArguments, OutArgs,
		LiveCode),

		% Figure out what variables will be live at the return point,
		% and where, for use in the accurate garbage collector, and
		% in the debugger.
	code_info__get_instmap(InstMap),
	{ goal_info_get_instmap_delta(GoalInfo, InstMapDelta) },
	{ instmap__apply_instmap_delta(InstMap, InstMapDelta, ReturnInstMap) },
	{ call_gen__output_arg_locs(ArgsInfos, OutputArgLocs) },
		% We must update the code generator state to reflect
		% the situation after the call before building
		% the return liveness info. No later code in this
		% predicate depends on the old state.
	call_gen__rebuild_registers(ArgsInfos),
	code_info__generate_return_live_lvalues(OutputArgLocs, ReturnInstMap,
		ReturnLiveLvalues),

		% Make the call.
	code_info__get_module_info(ModuleInfo),

	code_info__make_entry_label(ModuleInfo, PredId, ModeId, yes, Address),
	code_info__get_next_label(ReturnLabel),
	{ call_gen__call_comment(CodeModel, CallComment) },
	{ CallCode = node([
		call(Address, label(ReturnLabel), ReturnLiveLvalues, CallModel)
			- CallComment,
		label(ReturnLabel)
			- "continuation label"
	]) },

	call_gen__handle_failure(CodeModel, FailHandlingCode),

	{ Code =
		tree(SaveCode,
		tree(FlushCode,
		tree(SetupCode,
		tree(TraceCode,
		tree(LiveCode,
		tree(CallCode,
		     FailHandlingCode))))))
	}.

%---------------------------------------------------------------------------%

	%
	% For a generic_call,
	% we split the arguments into inputs and outputs, put the inputs
	% in the locations expected by mercury__do_call_closure in
	% runtime/mercury_ho_call.c, generate the call to that code,
	% and pick up the outputs from the locations that we know
	% the runtime system leaves them in.
	%

call_gen__generate_generic_call(_OuterCodeModel, GenericCall, Args,
		Modes, Det, GoalInfo, Code) -->
	list__map_foldl(code_info__variable_type, Args, Types),
	{ determinism_to_code_model(Det, CodeModel) },
	code_info__get_module_info(ModuleInfo),
	{ make_arg_infos(Types, Modes, CodeModel, ModuleInfo, ArgInfos) },
	{ assoc_list__from_corresponding_lists(Args, ArgInfos, ArgsInfos) },
	{ call_gen__partition_args(ArgsInfos, InVars, OutVars) },
	{ set__list_to_set(OutVars, OutArgs) },
	call_gen__save_variables(OutArgs, SaveCode),

	call_gen__prepare_for_call(CodeModel, FlushCode, CallModel),

	{ call_gen__generic_call_info(CodeModel, GenericCall,
		CodeAddr, FirstInput) },

		% place the immediate input arguments in registers
	call_gen__generate_immediate_args(InVars, FirstInput,
		InLocs, ImmediateCode),
	code_info__generate_call_stack_vn_livevals(OutArgs, LiveVals0),
	{ call_gen__extra_livevals(FirstInput, ExtraLiveVals) },
	{ set__insert_list(LiveVals0, ExtraLiveVals, LiveVals1) },
	{ set__insert_list(LiveVals1, InLocs, LiveVals) },

	{ CodeModel = model_semi ->
		FirstOutput = 2
	;
		FirstOutput = 1
	},
	{ call_gen__outvars_to_outargs(OutVars, FirstOutput, OutArguments) },
	{ call_gen__output_arg_locs(OutArguments, OutputArgLocs) },

	code_info__get_instmap(InstMap),
	{ goal_info_get_instmap_delta(GoalInfo, InstMapDelta) },
	{ instmap__apply_instmap_delta(InstMap, InstMapDelta, ReturnInstMap) },

		% Doing this after generating the immediate input arguments,
		% results in slightly more efficient code by not moving
		% the immediate arguments twice.
	call_gen__generic_call_setup(GenericCall, InVars, OutVars, SetupCode),

	trace__prepare_for_call(TraceCode),

		% We must update the code generator state to reflect
		% the situation after the call before building
		% the return liveness info. No later code in this
		% predicate depends on the old state.
	call_gen__rebuild_registers(OutArguments),
	code_info__generate_return_live_lvalues(OutputArgLocs, ReturnInstMap,
		ReturnLiveLvalues),

	code_info__get_next_label(ReturnLabel),
	{ CallCode = node([
		livevals(LiveVals)
			- "",
		call(CodeAddr, label(ReturnLabel), ReturnLiveLvalues,
			CallModel)
			- "Setup and call",
		label(ReturnLabel)
			- "Continuation label"
	]) },

	call_gen__handle_failure(CodeModel, FailHandlingCode),

	{ Code =
		tree(SaveCode,
		tree(FlushCode,
		tree(ImmediateCode,
		tree(SetupCode,
		tree(TraceCode,
		tree(CallCode,
		     FailHandlingCode))))))
	}.

	% The registers before the first input argument are all live.
:- pred call_gen__extra_livevals(int, list(lval)).
:- mode call_gen__extra_livevals(in, out) is det.

call_gen__extra_livevals(FirstInput, ExtraLiveVals) :-
	call_gen__extra_livevals(1, FirstInput, ExtraLiveVals). 

:- pred call_gen__extra_livevals(int, int, list(lval)).
:- mode call_gen__extra_livevals(in, in, out) is det.

call_gen__extra_livevals(Reg, FirstInput, ExtraLiveVals) :-
	( Reg < FirstInput ->
		ExtraLiveVals = [reg(r, Reg) | ExtraLiveVals1],
		NextReg is Reg + 1,
		call_gen__extra_livevals(NextReg, FirstInput, ExtraLiveVals1)
	;
		ExtraLiveVals = []
	).

	% call_gen__generic_call_info(CodeModel, GenericCall,
	% 	CodeAddr, FirstImmediateInputReg).
:- pred call_gen__generic_call_info(code_model, generic_call, code_addr, int).
:- mode call_gen__generic_call_info(in, in, out, out) is det.

call_gen__generic_call_info(_, higher_order(_, _, _), do_call_closure, 4).
call_gen__generic_call_info(_, class_method(_, _, _, _),
		do_call_class_method, 5).
call_gen__generic_call_info(CodeModel, aditi_builtin(aditi_call(_,_,_,_),_),
		CodeAddr, 5) :-
	( CodeModel = model_det, CodeAddr = do_det_aditi_call
	; CodeModel = model_semi, CodeAddr = do_semidet_aditi_call
	; CodeModel = model_non, CodeAddr = do_nondet_aditi_call
	).
call_gen__generic_call_info(CodeModel, aditi_builtin(aditi_insert(_), _),
		do_aditi_insert, 3) :-
	require(unify(CodeModel, model_det), "aditi_insert not model_det").
call_gen__generic_call_info(CodeModel, aditi_builtin(aditi_delete(_,_), _),
		do_aditi_delete, 2) :-
	require(unify(CodeModel, model_det), "aditi_delete not model_det").
call_gen__generic_call_info(CodeModel,
		aditi_builtin(aditi_bulk_operation(BulkOp, _), _),
		CodeAddr, 2) :-
	( BulkOp = insert, CodeAddr = do_aditi_bulk_insert
	; BulkOp = delete, CodeAddr = do_aditi_bulk_delete
	),
	require(unify(CodeModel, model_det),
		"aditi_bulk_operation not model_det").
call_gen__generic_call_info(CodeModel, aditi_builtin(aditi_modify(_,_), _),
		do_aditi_modify, 2) :-
	require(unify(CodeModel, model_det), "aditi_modify not model_det").

	% Produce code to set up the arguments to a generic call
	% that are always present, such as the closure for a higher-order call,
	% the typeclass_info for a class method call or the relation
	% name for an Aditi update operation.
:- pred call_gen__generic_call_setup(generic_call, list(prog_var),
	list(prog_var), code_tree, code_info, code_info).
:- mode call_gen__generic_call_setup(in, in, in, out, in, out) is det.

call_gen__generic_call_setup(higher_order(PredVar, _, _),
		InVars, OutVars, SetupCode) -->
	call_gen__place_generic_call_var(PredVar, "closure", PredVarCode),
	{ list__length(InVars, NInVars) },
	{ list__length(OutVars, NOutVars) },
	{ NumArgCode = node([
		assign(reg(r, 2), const(int_const(NInVars))) -
			"Assign number of immediate input arguments",
		assign(reg(r, 3), const(int_const(NOutVars))) -
			"Assign number of output arguments"
	]) },
	{ SetupCode = tree(PredVarCode, NumArgCode) }.
call_gen__generic_call_setup(class_method(TCVar, Method, _, _),
		InVars, OutVars, SetupCode) -->
	call_gen__place_generic_call_var(TCVar, "typeclass_info", TCVarCode),
	{ list__length(InVars, NInVars) },
	{ list__length(OutVars, NOutVars) },
	{ ArgsCode = node([
		assign(reg(r, 2), const(int_const(Method))) -
			"Index of class method in typeclass info",
		assign(reg(r, 3), const(int_const(NInVars))) -
			"Assign number of immediate input arguments",
		assign(reg(r, 4), const(int_const(NOutVars))) -
			"Assign number of output arguments"
	]) },
	{ SetupCode = tree(TCVarCode, ArgsCode) }.
call_gen__generic_call_setup(aditi_builtin(Builtin, _),
		InVars, OutVars, SetupCode) -->
	call_gen__aditi_builtin_setup(Builtin, InVars, OutVars,
		SetupCode).

:- pred call_gen__place_generic_call_var(prog_var, string, code_tree,
		code_info, code_info).
:- mode call_gen__place_generic_call_var(in, in, out, in, out) is det.

call_gen__place_generic_call_var(Var, Description, Code) -->
	code_info__produce_variable(Var, VarCode, VarRVal),
	{ VarRVal = lval(reg(r, 1)) ->
               CopyCode = empty
	;
	       % We don't need to clear r1 first - the arguments
	       % should have been moved into their proper positions and
	       % all other variables should have been saved by now.
	       string__append("Copy ", Description, Comment),
               CopyCode = node([
                       assign(reg(r, 1), VarRVal) - Comment
               ])
	},
	{ Code = tree(VarCode, CopyCode) }.

:- pred call_gen__aditi_builtin_setup(aditi_builtin,
	list(prog_var), list(prog_var), code_tree, code_info, code_info).
:- mode call_gen__aditi_builtin_setup(in, in, in, out, in, out) is det.

call_gen__aditi_builtin_setup(
		aditi_call(PredProcId, NumInputs, InputTypes, NumOutputs),
		_, _, SetupCode) -->
	code_info__get_module_info(ModuleInfo),
	{ rl__get_entry_proc_name(ModuleInfo, PredProcId, ProcName) },
	{ rl__proc_name_to_string(ProcName, ProcStr) },
	{ rl__schema_to_string(ModuleInfo, InputTypes, InputSchema) },
	{ SetupCode = node([
		assign(reg(r, 1), const(string_const(ProcStr))) -
			"Assign name of procedure to call",
		assign(reg(r, 2), const(int_const(NumInputs))) -
			"Assign number of input arguments",
		assign(reg(r, 3), const(string_const(InputSchema))) -
			"Assign schema of input arguments",
		assign(reg(r, 4), const(int_const(NumOutputs))) -
			"Assign number of output arguments"
	]) }.
call_gen__aditi_builtin_setup(aditi_insert(PredId), Inputs, _, SetupCode) -->
	call_gen__setup_base_relation_name(PredId, NameCode),
	{ list__length(Inputs, NumInputs) },
	{ SetupCode =
		tree(NameCode,
		node([
			assign(reg(r, 2), const(int_const(NumInputs))) -
				"Assign arity of relation to insert into"
		])
	) }.
call_gen__aditi_builtin_setup(aditi_delete(PredId, _), _, _, SetupCode) -->
	call_gen__setup_base_relation_name(PredId, SetupCode).
call_gen__aditi_builtin_setup(aditi_bulk_operation(_, PredId), _, _,
		SetupCode) -->
	call_gen__setup_base_relation_name(PredId, SetupCode).
call_gen__aditi_builtin_setup(aditi_modify(PredId, _), _, _, SetupCode) -->
	call_gen__setup_base_relation_name(PredId, SetupCode).

:- pred call_gen__setup_base_relation_name(pred_id,
		code_tree, code_info, code_info).
:- mode call_gen__setup_base_relation_name(in, out, in, out) is det.

call_gen__setup_base_relation_name(PredId, SetupCode) -->
	code_info__get_module_info(ModuleInfo),
	{ rl__permanent_relation_name(ModuleInfo, PredId, ProcStr) },
	{ SetupCode = node([
		assign(reg(r, 1), const(string_const(ProcStr))) -
			"Assign name of base relation"
	]) }.

%---------------------------------------------------------------------------%

:- pred call_gen__prepare_for_call(code_model, code_tree, call_model,
	code_info, code_info).
:- mode call_gen__prepare_for_call(in, out, out, in, out) is det.

call_gen__prepare_for_call(CodeModel, FlushCode, CallModel) -->
	code_info__succip_is_used,
	(
		{ CodeModel = model_det },
		{ CallModel = det },
		{ FlushCode = empty }
	;
		{ CodeModel = model_semi },
		{ CallModel = semidet },
		{ FlushCode = empty }
	;
		{ CodeModel = model_non },
		code_info__may_use_nondet_tailcall(TailCall),
		{ CallModel = nondet(TailCall) },
		code_info__flush_resume_vars_to_stack(FlushCode),
		code_info__set_resume_point_and_frame_to_unknown
	).

:- pred call_gen__handle_failure(code_model, code_tree, code_info, code_info).
:- mode call_gen__handle_failure(in, out, in, out ) is det.

call_gen__handle_failure(CodeModel, FailHandlingCode) -->
	( { CodeModel = model_semi } ->
		code_info__get_next_label(ContLab),
		{ FailTestCode = node([
			if_val(lval(reg(r, 1)), label(ContLab))
				- "test for success"
		]) },
		code_info__generate_failure(FailCode),
		{ ContLabelCode = node([
			label(ContLab)
				- ""
		]) },
		{ FailHandlingCode =
			tree(FailTestCode,
			tree(FailCode, 
			     ContLabelCode))
		}
	;
		{ FailHandlingCode = empty }
	).

:- pred call_gen__call_comment(code_model, string).
:- mode call_gen__call_comment(in, out) is det.

call_gen__call_comment(model_det,  "branch to det procedure").
call_gen__call_comment(model_semi, "branch to semidet procedure").
call_gen__call_comment(model_non,  "branch to nondet procedure").

%---------------------------------------------------------------------------%

call_gen__save_variables(Args, Code) -->
	code_info__get_known_variables(Variables0),
	{ set__list_to_set(Variables0, Vars0) },
	{ set__difference(Vars0, Args, Vars1) },
	code_info__get_globals(Globals),
	{ body_should_use_typeinfo_liveness(Globals, TypeInfoLiveness) },
	( 
		{ TypeInfoLiveness = yes }
	->
		code_info__get_proc_info(ProcInfo),
		{ proc_info_get_typeinfo_vars_setwise(ProcInfo, Vars1, 
			TypeInfoVars) },
		{ set__union(Vars1, TypeInfoVars, Vars) }
	;
		{ Vars = Vars1 }
	),
	{ set__to_sorted_list(Vars, Variables) },
	call_gen__save_variables_2(Variables, Code).

:- pred call_gen__save_variables_2(list(prog_var), code_tree,
		code_info, code_info).
:- mode call_gen__save_variables_2(in, out, in, out) is det.

call_gen__save_variables_2([], empty) --> [].
call_gen__save_variables_2([Var | Vars], Code) -->
	code_info__save_variable_on_stack(Var, CodeA),
	call_gen__save_variables_2(Vars, CodeB),
	{ Code = tree(CodeA, CodeB) }.

%---------------------------------------------------------------------------%

:- pred call_gen__rebuild_registers(assoc_list(prog_var, arg_info),
							code_info, code_info).
:- mode call_gen__rebuild_registers(in, in, out) is det.

call_gen__rebuild_registers(Args) -->
	code_info__clear_all_registers,
	call_gen__rebuild_registers_2(Args).

:- pred call_gen__rebuild_registers_2(assoc_list(prog_var, arg_info),
							code_info, code_info).
:- mode call_gen__rebuild_registers_2(in, in, out) is det.

call_gen__rebuild_registers_2([]) --> [].
call_gen__rebuild_registers_2([Var - arg_info(ArgLoc, Mode) | Args]) -->
	(
		{ Mode = top_out }
	->
		{ code_util__arg_loc_to_register(ArgLoc, Register) },
		code_info__set_var_location(Var, Register)
	;
		{ true }
	),
	call_gen__rebuild_registers_2(Args).

%---------------------------------------------------------------------------%

call_gen__generate_builtin(CodeModel, PredId, ProcId, Args, Code) -->
	code_info__get_module_info(ModuleInfo),
	{ predicate_module(ModuleInfo, PredId, ModuleName) },
	{ predicate_name(ModuleInfo, PredId, PredName) },
	{
		code_util__translate_builtin(ModuleName, PredName,
			ProcId, Args, MaybeTestPrime, MaybeAssignPrime)
	->
		MaybeTest = MaybeTestPrime,
		MaybeAssign = MaybeAssignPrime
	;
		error("Unknown builtin predicate")
	},
	(
		{ CodeModel = model_det },
		(
			{ MaybeTest = no },
			{ MaybeAssign = yes(Var - Rval) }
		->
			code_info__cache_expression(Var, Rval),
			{ Code = empty }
		;
			{ error("Malformed det builtin predicate") }
		)
	;
		{ CodeModel = model_semi },
		(
			{ MaybeTest = yes(Test) }
		->
			( { Test = binop(BinOp, X0, Y0) } ->
				call_gen__generate_builtin_arg(X0, X, CodeX),
				call_gen__generate_builtin_arg(Y0, Y, CodeY),
				{ Rval = binop(BinOp, X, Y) },
				{ ArgCode = tree(CodeX, CodeY) }
			; { Test = unop(UnOp, X0) } ->
				call_gen__generate_builtin_arg(X0, X, ArgCode),
				{ Rval = unop(UnOp, X) }
			;
				{ error("Malformed semi builtin predicate") }
			),
			code_info__fail_if_rval_is_false(Rval, TestCode),
			( { MaybeAssign = yes(Var - AssignRval) } ->
				code_info__cache_expression(Var, AssignRval)
			;
				[]
			),
			{ Code = tree(ArgCode, TestCode) }
		;
			{ error("Malformed semi builtin predicate") }
		)
	;
		{ CodeModel = model_non },
		{ error("Nondet builtin predicate") }
	).

%---------------------------------------------------------------------------%

:- pred call_gen__generate_builtin_arg(rval, rval, code_tree,
	code_info, code_info).
:- mode call_gen__generate_builtin_arg(in, out, out, in, out) is det.

call_gen__generate_builtin_arg(Rval0, Rval, Code) -->
	( { Rval0 = var(Var) } ->
		code_info__produce_variable(Var, Code, Rval)
	;
		{ Rval = Rval0 },
		{ Code = empty }
	).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

call_gen__partition_args([], [], []).
call_gen__partition_args([V - arg_info(_Loc,Mode) | Rest], Ins, Outs) :-
	(
		Mode = top_in
	->
		call_gen__partition_args(Rest, Ins0, Outs),
		Ins = [V | Ins0]
	;
		call_gen__partition_args(Rest, Ins, Outs0),
		Outs = [V | Outs0]
	).

%---------------------------------------------------------------------------%

:- pred call_gen__select_out_args(assoc_list(prog_var, arg_info),
		set(prog_var)).
:- mode call_gen__select_out_args(in, out) is det.

call_gen__select_out_args([], Out) :-
	set__init(Out).
call_gen__select_out_args([V - arg_info(_Loc, Mode) | Rest], Out) :-
	call_gen__select_out_args(Rest, Out0),
	(
		Mode = top_out
	->
		set__insert(Out0, V, Out)
	;
		Out = Out0
	).

%---------------------------------------------------------------------------%

:- pred call_gen__input_args(list(arg_info), list(arg_loc)).
:- mode call_gen__input_args(in, out) is det.

call_gen__input_args([], []).
call_gen__input_args([arg_info(Loc, Mode) | Args], Vs) :-
	(
		Mode = top_in
	->
		Vs = [Loc |Vs0]
	;
		Vs = Vs0
	),
	call_gen__input_args(Args, Vs0).

%---------------------------------------------------------------------------%

call_gen__input_arg_locs([], []).
call_gen__input_arg_locs([Var - arg_info(Loc, Mode) | Args], Vs) :-
	(
		Mode = top_in
	->
		Vs = [Var - Loc | Vs0]
	;
		Vs = Vs0
	),
	call_gen__input_arg_locs(Args, Vs0).

call_gen__output_arg_locs([], []).
call_gen__output_arg_locs([Var - arg_info(Loc, Mode) | Args], Vs) :-
	(
		Mode = top_out
	->
		Vs = [Var - Loc | Vs0]
	;
		Vs = Vs0
	),
	call_gen__output_arg_locs(Args, Vs0).

%---------------------------------------------------------------------------%

:- pred call_gen__generate_call_vn_livevals(list(arg_loc)::in,
	set(prog_var)::in, code_tree::out,
	code_info::in, code_info::out) is det.

call_gen__generate_call_vn_livevals(InputArgLocs, OutputArgs, Code) -->
	code_info__generate_call_vn_livevals(InputArgLocs, OutputArgs,
		LiveVals),
	{ Code = node([
		livevals(LiveVals) - ""
	]) }.

%---------------------------------------------------------------------------%

:- pred call_gen__generate_immediate_args(list(prog_var), int, list(lval),
		code_tree, code_info, code_info).
:- mode call_gen__generate_immediate_args(in, in, out, out, in, out) is det.

call_gen__generate_immediate_args([], _N, [], empty) --> [].
call_gen__generate_immediate_args([V | Vs], N0, [Lval | Lvals], Code) -->
	{ Lval = reg(r, N0) },
	code_info__place_var(V, Lval, Code0),
	{ N1 is N0 + 1 },
	call_gen__generate_immediate_args(Vs, N1, Lvals, Code1),
	{ Code = tree(Code0, Code1) }.

%---------------------------------------------------------------------------%

:- pred call_gen__outvars_to_outargs(list(prog_var), int,
		assoc_list(prog_var, arg_info)).
:- mode call_gen__outvars_to_outargs(in, in, out) is det.

call_gen__outvars_to_outargs([], _N, []).
call_gen__outvars_to_outargs([V | Vs], N0, [V - Arg | ArgInfos]) :-
	Arg = arg_info(N0, top_out),
	N1 is N0 + 1,
	call_gen__outvars_to_outargs(Vs, N1, ArgInfos).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%
