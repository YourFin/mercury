%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 2010-2012 The University of Melbourne.
% Copyright (C) 2013-2018 The Mercury team.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%

% Output MLDS statements in C#.
%
% About multiple outputs: C# supports pass-by-reference, so the first thought
% is to just let the MLDS code generator use `out' parameters to handle
% multiple outputs. But to reference a method, we have to assign it
% to a delegate with a matching signature, which needs to be declared.
% Although we can parameterise the types, we cannot parameterise
% the argument modes (in/out), so we would need 2^n delegates to cover
% all methods of arity n.
%
% Instead, we generate code as if C# supported multiple return values.
% The first return value is returned as usual. The second and later return
% values are assigned to `out' parameters, which we always place after any
% input arguments. That way we don't need to declare delegates with all
% possible permutations of in/out parameters.
%
%---------------------------------------------------------------------------%

:- module ml_backend.mlds_to_cs_stmt.
:- interface.

:- import_module ml_backend.mlds.
:- import_module ml_backend.mlds_to_cs_util.
:- import_module ml_backend.mlds_to_target_util.

:- import_module io.

%---------------------------------------------------------------------------%

:- pred output_stmt_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in, exit_methods::out,
    io::di, io::uo) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.
:- import_module backend_libs.rtti.
:- import_module hlds.
:- import_module hlds.hlds_module.
:- import_module libs.
:- import_module libs.globals.
:- import_module ml_backend.mlds_to_cs_data.
:- import_module ml_backend.mlds_to_cs_func.    % undesirable circular dep
:- import_module ml_backend.mlds_to_cs_name.
:- import_module ml_backend.mlds_to_cs_type.
:- import_module parse_tree.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_type.

:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module require.
:- import_module set.
:- import_module string.
:- import_module term.

%---------------------------------------------------------------------------%

output_stmt_for_csharp(Info, Indent, FuncInfo, Stmt, ExitMethods, !IO) :-
    (
        Stmt = ml_stmt_block(_, _, _, _),
        output_stmt_block_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_while(_, _, _, _, _),
        output_stmt_while_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_if_then_else(_, _, _, _),
        output_stmt_if_then_else_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_switch(_, _, _, _, _, _),
        output_stmt_switch_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_label(_, _),
        unexpected($pred, "labels not supported in C#.")
    ;
        Stmt = ml_stmt_goto(_, _),
        output_stmt_goto_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_computed_goto(_, _, _),
        unexpected($pred, "computed gotos not supported in C#.")
    ;
        Stmt = ml_stmt_call(_, _, _, _, _, _),
        output_stmt_call_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_return(_, _),
        output_stmt_return_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_do_commit(_, _),
        output_stmt_do_commit_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_try_commit(_, _, _, _),
        output_stmt_try_commit_for_csharp(Info, Indent, FuncInfo, Stmt,
            ExitMethods, !IO)
    ;
        Stmt = ml_stmt_atomic(AtomicStatement, Context),
        output_atomic_stmt_for_csharp(Info, Indent, AtomicStatement,
            Context, !IO),
        ExitMethods = set.make_singleton_set(can_fall_through)
    ).

:- pred output_stmt_block_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_block),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_block_for_csharp/7).

output_stmt_block_for_csharp(Info, Indent, FuncInfo, Stmt,
        ExitMethods, !IO) :-
    Stmt = ml_stmt_block(LocalVarDefns, FuncDefns, Stmts, Context),
    BraceIndent = Indent,
    BlockIndent = Indent + 1,
    indent_line_after_context(Info ^ csoi_line_numbers, Context,
        BraceIndent, !IO),
    io.write_string("{\n", !IO),
    (
        LocalVarDefns = [_ | _],
        list.foldl(
            output_local_var_defn_for_csharp(Info, BlockIndent, oa_force_init),
            LocalVarDefns, !IO),
        io.write_string("\n", !IO)
    ;
        LocalVarDefns = []
    ),
    (
        FuncDefns = [_ | _],
        list.foldl(
            output_function_defn_for_csharp(Info, BlockIndent, oa_force_init),
            FuncDefns, !IO),
        io.write_string("\n", !IO)
    ;
        FuncDefns = []
    ),
    output_stmts_for_csharp(Info, BlockIndent, FuncInfo, Stmts,
        ExitMethods, !IO),
    indent_line_after_context(Info ^ csoi_line_numbers, Context,
        BraceIndent, !IO),
    io.write_string("}\n", !IO).

:- pred output_local_var_defn_for_csharp(csharp_out_info::in, indent::in,
    output_aux::in, mlds_local_var_defn::in, io::di, io::uo) is det.

output_local_var_defn_for_csharp(Info, Indent, OutputAux, LocalVarDefn, !IO) :-
    output_n_indents(Indent, !IO),
    LocalVarDefn = mlds_local_var_defn(LocalVarName, _Context,
        Type, Initializer, _),
    output_local_var_decl_for_csharp(Info, LocalVarName, Type, !IO),
    output_initializer_for_csharp(Info, OutputAux, Type, Initializer, !IO),
    io.write_string(";\n", !IO).

:- pred output_local_var_decl_for_csharp(csharp_out_info::in,
    mlds_local_var_name::in, mlds_type::in, io::di, io::uo) is det.

output_local_var_decl_for_csharp(Info, LocalVarName, Type, !IO) :-
    output_type_for_csharp(Info, Type, !IO),
    io.write_char(' ', !IO),
    output_local_var_name_for_csharp(LocalVarName, !IO).

:- pred output_stmts_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, list(mlds_stmt)::in, exit_methods::out,
    io::di, io::uo) is det.

output_stmts_for_csharp(_, _, _, [], ExitMethods, !IO) :-
    ExitMethods = set.make_singleton_set(can_fall_through).
output_stmts_for_csharp(Info, Indent, FuncInfo, [Stmt | Stmts],
        ExitMethods, !IO) :-
    output_stmt_for_csharp(Info, Indent, FuncInfo, Stmt,
        StmtExitMethods, !IO),
    ( if set.member(can_fall_through, StmtExitMethods) then
        output_stmts_for_csharp(Info, Indent, FuncInfo, Stmts,
            StmtsExitMethods, !IO),
        ExitMethods0 = set.union(StmtExitMethods, StmtsExitMethods),
        ( if set.member(can_fall_through, StmtsExitMethods) then
            ExitMethods = ExitMethods0
        else
            % If the last statement could not complete normally
            % the current block can no longer complete normally.
            ExitMethods = set.delete(ExitMethods0, can_fall_through)
        )
    else
        % Don't output any more statements from the current list since
        % the preceding statement cannot complete.
        ExitMethods = StmtExitMethods
    ).

%---------------------------------------------------------------------------%

:- pred output_stmt_while_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_while),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_while_for_csharp/7).

output_stmt_while_for_csharp(Info, Indent, FuncInfo, Stmt, ExitMethods, !IO) :-
    Stmt = ml_stmt_while(Kind, Cond, BodyStmt, _LoopLocalVars, Context),
    scope_indent(BodyStmt, Indent, ScopeIndent),
    (
        Kind = may_loop_zero_times,
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("while (", !IO),
        output_rval_for_csharp(Info, Cond, !IO),
        io.write_string(")\n", !IO),
        % The contained statement is reachable iff the while statement is
        % reachable and the condition expression is not a constant
        % expression whose value is false.
        ( if Cond = ml_const(mlconst_false) then
            indent_line_after_context(Info ^ csoi_line_numbers, Context,
                Indent, !IO),
            io.write_string("{\n", !IO),
            output_n_indents(Indent + 1, !IO),
            io.write_string("/* Unreachable code */\n", !IO),
            output_n_indents(Indent, !IO),
            io.write_string("}\n", !IO),
            ExitMethods = set.make_singleton_set(can_fall_through)
        else
            BodyInfo = Info ^ csoi_break_context := bc_loop,
            output_stmt_for_csharp(BodyInfo, ScopeIndent, FuncInfo, BodyStmt,
                StmtExitMethods, !IO),
            ExitMethods = while_exit_methods_for_csharp(Cond, StmtExitMethods)
        )
    ;
        Kind = loop_at_least_once,
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("do\n", !IO),
        BodyInfo = Info ^ csoi_break_context := bc_loop,
        output_stmt_for_csharp(BodyInfo, ScopeIndent, FuncInfo, BodyStmt,
            StmtExitMethods, !IO),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("while (", !IO),
        output_rval_for_csharp(Info, Cond, !IO),
        io.write_string(");\n", !IO),
        ExitMethods = while_exit_methods_for_csharp(Cond, StmtExitMethods)
    ).

:- func while_exit_methods_for_csharp(mlds_rval, exit_methods) = exit_methods.

while_exit_methods_for_csharp(Cond, BlockExitMethods) = ExitMethods :-
    % A while statement cannot complete normally if its condition
    % expression is a constant expression with value true, and it
    % doesn't contain a reachable break statement that exits the
    % while statement.
    ( if
        % XXX This is not a sufficient way of testing for a Java
        % "constant expression", though determining these accurately
        % is a little difficult to do here.
        % XXX C# is not Java
        Cond = ml_const(mlconst_true),
        not set.member(can_break, BlockExitMethods)
    then
        % Cannot complete normally.
        ExitMethods0 = set.delete(BlockExitMethods, can_fall_through)
    else
        ExitMethods0 = set.insert(BlockExitMethods, can_fall_through)
    ),
    ExitMethods = set.delete_list(ExitMethods0, [can_continue, can_break]).

%---------------------------------------------------------------------------%

:- pred output_stmt_if_then_else_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_if_then_else),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_if_then_else_for_csharp/7).

output_stmt_if_then_else_for_csharp(Info, Indent, FuncInfo, Stmt,
        ExitMethods, !IO) :-
    Stmt = ml_stmt_if_then_else(Cond, Then0, MaybeElse, Context),
    % We need to take care to avoid problems caused by the dangling else
    % ambiguity.
    ( if
        % For examples of the form
        %
        %   if (...)
        %       if (...)
        %           ...
        %   else
        %       ...
        %
        % we need braces around the inner `if', otherwise they wouldn't
        % parse they way we want them to.

        MaybeElse = yes(_),
        Then0 = ml_stmt_if_then_else(_, _, no, ThenContext)
    then
        Then = ml_stmt_block([], [], [Then0], ThenContext)
    else
        Then = Then0
    ),

    indent_line_after_context(Info ^ csoi_line_numbers, Context, Indent, !IO),
    io.write_string("if (", !IO),
    output_rval_for_csharp(Info, Cond, !IO),
    io.write_string(")\n", !IO),
    scope_indent(Then, Indent, ThenScopeIndent),
    output_stmt_for_csharp(Info, ThenScopeIndent, FuncInfo, Then,
        ThenExitMethods, !IO),
    (
        MaybeElse = yes(Else),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("else\n", !IO),
        scope_indent(Else, Indent, ElseScopeIndent),
        output_stmt_for_csharp(Info, ElseScopeIndent, FuncInfo, Else,
            ElseExitMethods, !IO),
        % An if-then-else statement can complete normally iff the
        % then-statement can complete normally or the else-statement
        % can complete normally.
        ExitMethods = set.union(ThenExitMethods, ElseExitMethods)
    ;
        MaybeElse = no,
        % An if-then statement can complete normally iff it is reachable.
        ExitMethods = set.insert(ThenExitMethods, can_fall_through)
    ).

%---------------------------------------------------------------------------%

:- pred output_stmt_switch_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_switch),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_switch_for_csharp/7).

output_stmt_switch_for_csharp(Info, Indent, FuncInfo, Stmt,
        ExitMethods, !IO) :-
    Stmt = ml_stmt_switch(_Type, Val, _Range, Cases, Default, Context),
    indent_line_after_context(Info ^ csoi_line_numbers, Context, Indent, !IO),
    io.write_string("switch (", !IO),
    output_rval_for_csharp(Info, Val, !IO),
    io.write_string(") {\n", !IO),
    CaseInfo = Info ^ csoi_break_context := bc_switch,
    output_switch_cases_for_csharp(CaseInfo, Indent + 1, FuncInfo, Context,
        Cases, Default, ExitMethods, !IO),
    indent_line_after_context(Info ^ csoi_line_numbers, Context, Indent, !IO),
    io.write_string("}\n", !IO).

:- pred output_switch_cases_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, prog_context::in, list(mlds_switch_case)::in,
    mlds_switch_default::in, exit_methods::out, io::di, io::uo) is det.

output_switch_cases_for_csharp(Info, Indent, FuncInfo, Context,
        [], Default, ExitMethods, !IO) :-
    output_switch_default_for_csharp(Info, Indent, FuncInfo, Context, Default,
        ExitMethods, !IO).
output_switch_cases_for_csharp(Info, Indent, FuncInfo, Context,
        [Case | Cases], Default, ExitMethods, !IO) :-
    output_switch_case_for_csharp(Info, Indent, FuncInfo, Context, Case,
        CaseExitMethods0, !IO),
    output_switch_cases_for_csharp(Info, Indent, FuncInfo, Context, Cases,
        Default, CasesExitMethods, !IO),
    ( if set.member(can_break, CaseExitMethods0) then
        CaseExitMethods = set.insert(set.delete(CaseExitMethods0, can_break),
            can_fall_through)
    else
        CaseExitMethods = CaseExitMethods0
    ),
    ExitMethods = set.union(CaseExitMethods, CasesExitMethods).

:- pred output_switch_case_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, prog_context::in, mlds_switch_case::in,
    exit_methods::out, io::di, io::uo) is det.

output_switch_case_for_csharp(Info, Indent, FuncInfo, Context, Case,
        ExitMethods, !IO) :-
    Case = mlds_switch_case(FirstCond, LaterConds, Statement),
    output_case_cond_for_csharp(Info, Indent, Context, FirstCond, !IO),
    list.foldl(output_case_cond_for_csharp(Info, Indent, Context), LaterConds,
        !IO),
    output_stmt_for_csharp(Info, Indent + 1, FuncInfo, Statement,
        StmtExitMethods, !IO),
    ( if set.member(can_fall_through, StmtExitMethods) then
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent + 1, !IO),
        io.write_string("break;\n", !IO),
        ExitMethods = set.delete(set.insert(StmtExitMethods, can_break),
            can_fall_through)
    else
        % Don't output `break' since it would be unreachable.
        ExitMethods = StmtExitMethods
    ).

:- pred output_case_cond_for_csharp(csharp_out_info::in, indent::in,
    prog_context::in, mlds_case_match_cond::in, io::di, io::uo) is det.

output_case_cond_for_csharp(Info, Indent, Context, Match, !IO) :-
    (
        Match = match_value(Val),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("case ", !IO),
        output_rval_for_csharp(Info, Val, !IO),
        io.write_string(":\n", !IO)
    ;
        Match = match_range(_, _),
        unexpected($pred, "cannot match ranges in C# cases")
    ).

:- pred output_switch_default_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, prog_context::in, mlds_switch_default::in,
    exit_methods::out, io::di, io::uo) is det.

output_switch_default_for_csharp(Info, Indent, FuncInfo, Context, Default,
        ExitMethods, !IO) :-
    (
        Default = default_do_nothing,
        ExitMethods = set.make_singleton_set(can_fall_through)
    ;
        Default = default_case(Statement),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("default:\n", !IO),
        output_stmt_for_csharp(Info, Indent + 1, FuncInfo, Statement,
            ExitMethods, !IO),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("break;\n", !IO)
    ;
        Default = default_is_unreachable,
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("default: /*NOTREACHED*/\n", !IO),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent + 1, !IO),
        io.write_string("throw new runtime.UnreachableDefault();\n", !IO),
        ExitMethods = set.make_singleton_set(can_throw)
    ).

%---------------------------------------------------------------------------%

:- pred output_stmt_goto_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_goto),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_goto_for_csharp/7).

output_stmt_goto_for_csharp(Info, Indent, _FuncInfo, Stmt, ExitMethods, !IO) :-
    Stmt = ml_stmt_goto(Target, Context),
    (
        Target = goto_label(_),
        unexpected($pred, "gotos not supported in C#.")
    ;
        Target = goto_break_switch,
        BreakContext = Info ^ csoi_break_context,
        (
            BreakContext = bc_switch,
            indent_line_after_context(Info ^ csoi_line_numbers, Context,
                Indent, !IO),
            io.write_string("break;\n", !IO),
            ExitMethods = set.make_singleton_set(can_break)
        ;
            ( BreakContext = bc_none
            ; BreakContext = bc_loop
            ),
            unexpected($pred, "goto_break_switch not in switch")
        )
    ;
        Target = goto_break_loop,
        BreakContext = Info ^ csoi_break_context,
        (
            BreakContext = bc_loop,
            indent_line_after_context(Info ^ csoi_line_numbers, Context,
                Indent, !IO),
            io.write_string("break;\n", !IO),
            ExitMethods = set.make_singleton_set(can_break)
        ;
            ( BreakContext = bc_none
            ; BreakContext = bc_switch
            ),
            unexpected($pred, "goto_break_loop not in loop")
        )
    ;
        Target = goto_continue_loop,
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("continue;\n", !IO),
        ExitMethods = set.make_singleton_set(can_continue)
    ).

%---------------------------------------------------------------------------%

:- pred output_stmt_call_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_call),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_call_for_csharp/7).

output_stmt_call_for_csharp(Info, Indent, _FuncInfo, Stmt,
        ExitMethods, !IO) :-
    Stmt = ml_stmt_call(Signature, FuncRval, CallArgs, Results,
        IsTailCall, Context),
    Signature = mlds_func_signature(ArgTypes, RetTypes),
    indent_line_after_context(Info ^ csoi_line_numbers, Context,
        Indent, !IO),
    io.write_string("{\n", !IO),
    indent_line_after_context(Info ^ csoi_line_numbers, Context,
        Indent + 1, !IO),
    (
        Results = [],
        OutArgs = []
    ;
        Results = [Lval | Lvals],
        output_lval_for_csharp(Info, Lval, !IO),
        io.write_string(" = ", !IO),
        OutArgs = list.map(func(X) = ml_mem_addr(X), Lvals)
    ),
    ( if FuncRval = ml_const(mlconst_code_addr(_)) then
        % This is a standard method call.
        CloseBracket = ""
    else
        % This is a call using a method pointer.
        TypeString = method_ptr_type_to_string(Info, ArgTypes, RetTypes),
        io.format("((%s) ", [s(TypeString)], !IO),
        CloseBracket = ")"
    ),
    output_call_rval_for_csharp(Info, FuncRval, !IO),
    io.write_string(CloseBracket, !IO),
    io.write_string("(", !IO),
    io.write_list(CallArgs ++ OutArgs, ", ",
        output_rval_for_csharp(Info), !IO),
    io.write_string(");\n", !IO),

    % This is to tell the C# compiler that a call to an erroneous procedure
    % will not fall through. --pw
    (
        IsTailCall = ordinary_call
    ;
        IsTailCall = tail_call
    ;
        IsTailCall = no_return_call,
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent  + 1, !IO),
        io.write_string("throw new runtime.UnreachableDefault();\n", !IO)
    ),

    indent_line_after_context(Info ^ csoi_line_numbers, Context, Indent, !IO),
    io.write_string("}\n", !IO),
    ExitMethods = set.make_singleton_set(can_fall_through).

%---------------------------------------------------------------------------%

:- pred output_stmt_return_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_return),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_return_for_csharp/7).

output_stmt_return_for_csharp(Info, Indent, _FuncInfo, Stmt,
        ExitMethods, !IO) :-
    Stmt = ml_stmt_return(Results, Context),
    (
        Results = [],
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("return;\n", !IO)
    ;
        Results = [Rval | Rvals],
        % The first return value is returned directly.
        % Subsequent return values are assigned to out parameters.
        list.foldl2(output_assign_out_params(Info, Indent), Rvals, 2, _, !IO),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("return ", !IO),
        output_rval_for_csharp(Info, Rval, !IO),
        io.write_string(";\n", !IO)
    ),
    ExitMethods = set.make_singleton_set(can_return).

:- pred output_assign_out_params(csharp_out_info::in, indent::in,
    mlds_rval::in, int::in, int::out, io::di, io::uo) is det.

output_assign_out_params(Info, Indent, Rval, Num, Num + 1, !IO) :-
    output_n_indents(Indent, !IO),
    io.format("out_param_%d = ", [i(Num)], !IO),
    output_rval_for_csharp(Info, Rval, !IO),
    io.write_string(";\n", !IO).

%---------------------------------------------------------------------------%

:- pred output_stmt_do_commit_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_do_commit),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_do_commit_for_csharp/7).

output_stmt_do_commit_for_csharp(Info, Indent, _FuncInfo, Stmt,
        ExitMethods, !IO) :-
    Stmt = ml_stmt_do_commit(Ref, Context),
    indent_line_after_context(Info ^ csoi_line_numbers, Context, Indent, !IO),
    output_rval_for_csharp(Info, Ref, !IO),
    io.write_string(" = new runtime.Commit();\n", !IO),
    indent_line_after_context(Info ^ csoi_line_numbers, Context, Indent, !IO),
    io.write_string("throw ", !IO),
    output_rval_for_csharp(Info, Ref, !IO),
    io.write_string(";\n", !IO),
    ExitMethods = set.make_singleton_set(can_throw).

%---------------------------------------------------------------------------%

:- pred output_stmt_try_commit_for_csharp(csharp_out_info::in, indent::in,
    func_info_csj::in, mlds_stmt::in(ml_stmt_is_try_commit),
    exit_methods::out, io::di, io::uo) is det.
:- pragma inline(output_stmt_try_commit_for_csharp/7).

output_stmt_try_commit_for_csharp(Info, Indent, FuncInfo, Stmt,
        ExitMethods, !IO) :-
    Stmt = ml_stmt_try_commit(_Ref, BodyStmt, HandlerStmt, Context),
    LineNumbers = Info ^ csoi_line_numbers,
    indent_line_after_context(LineNumbers, Context, Indent, !IO),
    io.write_string("try\n", !IO),
    indent_line_after_context(LineNumbers, Context, Indent, !IO),
    io.write_string("{\n", !IO),
    output_stmt_for_csharp(Info, Indent + 1, FuncInfo, BodyStmt,
        TryExitMethods0, !IO),
    indent_line_after_context(LineNumbers, Context, Indent, !IO),
    io.write_string("}\n", !IO),
    indent_line_after_context(LineNumbers, Context, Indent, !IO),
    io.write_string("catch (runtime.Commit commit_variable)\n", !IO),
    indent_line_after_context(LineNumbers, Context, Indent, !IO),
    io.write_string("{\n", !IO),
    indent_line_after_context(LineNumbers, Context, Indent + 1, !IO),
    output_stmt_for_csharp(Info, Indent + 1, FuncInfo, HandlerStmt,
        CatchExitMethods, !IO),
    indent_line_after_context(LineNumbers, Context, Indent, !IO),
    io.write_string("}\n", !IO),
    ExitMethods = set.union(set.delete(TryExitMethods0, can_throw),
        CatchExitMethods).

%---------------------------------------------------------------------------%

:- pred output_atomic_stmt_for_csharp(csharp_out_info::in, indent::in,
    mlds_atomic_statement::in, prog_context::in, io::di, io::uo) is det.

output_atomic_stmt_for_csharp(Info, Indent, AtomicStmt, Context, !IO) :-
    (
        AtomicStmt = comment(Comment),
        ( if Comment = "" then
            io.nl(!IO)
        else
            % XXX We should escape any "*/"'s in the Comment. We should also
            % split the comment into lines and indent each line appropriately.
            output_n_indents(Indent, !IO),
            io.write_string("/* ", !IO),
            io.write_string(Comment, !IO),
            io.write_string(" */\n", !IO)
        )
    ;
        AtomicStmt = assign(Lval, Rval),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        output_lval_for_csharp(Info, Lval, !IO),
        io.write_string(" = ", !IO),
        output_rval_for_csharp(Info, Rval, !IO),
        io.write_string(";\n", !IO)
    ;
        AtomicStmt = assign_if_in_heap(_, _),
        sorry($pred, "assign_if_in_heap")
    ;
        AtomicStmt = delete_object(_Lval),
        unexpected($pred, "delete_object not supported in C#.")
    ;
        AtomicStmt = new_object(Target, _Ptag, ExplicitSecTag, Type,
            _MaybeSize, MaybeCtorName, ArgRvalsTypes, _MayUseAtomic, _AllocId),
        (
            ExplicitSecTag = yes,
            unexpected($pred, "explicit secondary tag")
        ;
            ExplicitSecTag = no
        ),

        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("{\n", !IO),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent + 1, !IO),
        output_lval_for_csharp(Info, Target, !IO),
        io.write_string(" = new ", !IO),
        % Generate class constructor name.
        ( if
            MaybeCtorName = yes(QualifiedCtorId),
            not (
                Type = mercury_nb_type(MerType, CtorCat),
                hand_defined_type_for_csharp(MerType, CtorCat, _, _)
            )
        then
            output_type_for_csharp(Info, Type, !IO),
            io.write_char('.', !IO),
            QualifiedCtorId = qual_ctor_id(_ModuleName, _QualKind, CtorDefn),
            CtorDefn = ctor_id(CtorName, CtorArity),
            output_unqual_class_name_for_csharp(CtorName, CtorArity, !IO)
        else
            output_type_for_csharp(Info, Type, !IO)
        ),
        IsArray = type_is_array_for_csharp(Type),
        (
            IsArray = is_array,
            % The new object will be an array, so we need to initialise it
            % using array literals syntax.
            io.write_string(" {", !IO),
            output_init_args_for_csharp(Info, ArgRvalsTypes, !IO),
            io.write_string("};\n", !IO)
        ;
            IsArray = not_array,
            % Generate constructor arguments.
            io.write_string("(", !IO),
            output_init_args_for_csharp(Info, ArgRvalsTypes, !IO),
            io.write_string(");\n", !IO)
        ),
        indent_line_after_context(Info ^ csoi_line_numbers, Context,
            Indent, !IO),
        io.write_string("}\n", !IO)
    ;
        AtomicStmt = gc_check,
        unexpected($pred, "gc_check not implemented.")
    ;
        AtomicStmt = mark_hp(_Lval),
        unexpected($pred, "mark_hp not implemented.")
    ;
        AtomicStmt = restore_hp(_Rval),
        unexpected($pred, "restore_hp not implemented.")
    ;
        AtomicStmt = trail_op(_TrailOp),
        unexpected($pred, "trail_ops not implemented.")
    ;
        AtomicStmt = inline_target_code(TargetLang, Components),
        (
            TargetLang = ml_target_csharp,
            output_pragma_warning_restore(!IO),
            list.foldl(output_target_code_component_for_csharp(Info),
                Components, !IO),
            output_pragma_warning_disable(!IO)
        ;
            ( TargetLang = ml_target_c
            ; TargetLang = ml_target_java
            ),
            unexpected($pred, "inline_target_code only works for lang_java")
        )
    ;
        AtomicStmt = outline_foreign_proc(_TargetLang, _Vs, _Lvals, _Code),
        unexpected($pred, "foreign language interfacing not implemented")
    ).

    % Output initial values of an object's fields as arguments for the
    % object's class constructor.
    %
:- pred output_init_args_for_csharp(csharp_out_info::in,
    list(mlds_typed_rval)::in, io::di, io::uo) is det.

output_init_args_for_csharp(_, [], !IO).
output_init_args_for_csharp(Info, [ArgRvalType | ArgRvalsTypes], !IO) :-
    ArgRvalType = ml_typed_rval(ArgRval, _ArgType),
    output_rval_for_csharp(Info, ArgRval, !IO),
    (
        ArgRvalsTypes = []
    ;
        ArgRvalsTypes = [_ | _],
        io.write_string(", ", !IO)
    ),
    output_init_args_for_csharp(Info, ArgRvalsTypes, !IO).

:- pred output_target_code_component_for_csharp(csharp_out_info::in,
    target_code_component::in, io::di, io::uo) is det.

output_target_code_component_for_csharp(Info, TargetCode, !IO) :-
    (
        TargetCode = user_target_code(CodeString, MaybeUserContext),
        io.write_string("{\n", !IO),
        (
            MaybeUserContext = yes(ProgContext),
            cs_output_context(Info ^ csoi_foreign_line_numbers,
                ProgContext, !IO)
        ;
            MaybeUserContext = no
        ),
        io.write_string(CodeString, !IO),
        io.write_string("}\n", !IO),
        cs_output_default_context(Info ^ csoi_foreign_line_numbers, !IO)
    ;
        TargetCode = raw_target_code(CodeString),
        io.write_string(CodeString, !IO)
    ;
        TargetCode = target_code_input(Rval),
        output_rval_for_csharp(Info, Rval, !IO)
    ;
        TargetCode = target_code_output(Lval),
        output_lval_for_csharp(Info, Lval, !IO)
    ;
        TargetCode = target_code_type(Type),
        % XXX enable generics here
        output_type_for_csharp(Info, Type, !IO)
    ;
        TargetCode = target_code_function_name(FuncName),
        output_maybe_qualified_function_name_for_csharp(Info, FuncName, !IO)
    ;
        TargetCode = target_code_alloc_id(_),
        unexpected($pred, "target_code_alloc_id not implemented")
    ).

%---------------------------------------------------------------------------%
:- end_module ml_backend.mlds_to_cs_stmt.
%---------------------------------------------------------------------------%
