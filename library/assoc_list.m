%---------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%

% File: assoc_list.m.
% Main authors: fjh, zs.
% Stability: medium to high.

% This file contains the definition of the type assoc_list(K, V)
% and some predicates which operate on those types.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module assoc_list.

:- interface.

:- import_module list, std_util.

%-----------------------------------------------------------------------------%

:- type assoc_list(K,V)	==	list(pair(K,V)).

:- type assoc_list(T)	==	list(pair(T,T)).

:- pred assoc_list__reverse_members(assoc_list(K, V), assoc_list(V, K)).
:- mode assoc_list__reverse_members(in, out) is det.

:- pred assoc_list__from_corresponding_lists(list(K), list(V), assoc_list(K,V)).
:- mode assoc_list__from_corresponding_lists(in, in, out) is det.

:- pred assoc_list__keys(assoc_list(K, V), list(K)).
:- mode assoc_list__keys(in, out) is det.

:- pred assoc_list__values(assoc_list(K, V), list(V)).
:- mode assoc_list__values(in, out) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module require, set.

assoc_list__reverse_members([], []).
assoc_list__reverse_members([K - V | KVs], [V - K | VKs]) :-
	assoc_list__reverse_members(KVs, VKs).

assoc_list__from_corresponding_lists(Ks, Vs, KVs) :-
	( assoc_list__from_corresponding_2(Ks, Vs, KVs0) ->
		KVs = KVs0
	;
		error("assoc_list__from_corresponding_lists: lists have different lengths.")
	).

:- pred assoc_list__from_corresponding_2(list(K), list(V), assoc_list(K,V)).
:- mode assoc_list__from_corresponding_2(in, in, out) is semidet.

assoc_list__from_corresponding_2([], [], []).
assoc_list__from_corresponding_2([A | As], [B | Bs], [A - B | ABs]) :-
	assoc_list__from_corresponding_2(As, Bs, ABs).

assoc_list__keys([], []).
assoc_list__keys([K - _ | KVs], [K | Ks]) :-
	assoc_list__keys(KVs, Ks).

assoc_list__values([], []).
assoc_list__values([_ - V | KVs], [V | Vs]) :-
	assoc_list__values(KVs, Vs).

%-----------------------------------------------------------------------------%
