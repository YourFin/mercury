%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%
%
% This module imports all the modules in the Mercury library.
%
% It is used as a way for the Makefiles to know which library interface
% files, objects, etc., need to be installed, and it is also linked to
% create the executable invoked by the `mnp' script.
% 
% ---------------------------------------------------------------------------%
% ---------------------------------------------------------------------------%

:- module library.

:- interface.

:- import_module array, bag, bimap, bintree, bintree_set, char, dir.
:- import_module float, graph, group, int, io.
:- import_module list, map, pqueue, queue, random, require.
:- import_module set, stack, std_util, string, term, term_io.
:- import_module tree234, varset, store.

:- import_module parser, lexer, ops.

:- implementation.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%
