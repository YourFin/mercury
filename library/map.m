%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
%
% Main author: fjh.
%
% This file provides the 'map' ADT.
% A map (also known as a dictionary or an associative array) is a collection
% of (Key,Data) pairs which allows you to look up any Data item given the
% Key.
%
% The implementation is using balanced binary trees, as provided by
% tree234.nl.  Virtually all the predicates in this file just
% forward the work to the corresponding predicate in tree234.nl.
%
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module map.
:- interface.
:- import_module set, list, std_util, require.

%-----------------------------------------------------------------------------%

:- type map(_K, _V).

%-----------------------------------------------------------------------------%

	% Initialize an empty map.
:- pred map__init(map(_,_)).
:- mode map__init(out) is det.

	% Check whether a map is empty.
:- pred map__is_empty(map(_,_)).
:- mode map__is_empty(in) is semidet.

	% Check whether map contains key
:- pred map__contains(map(K,_V), K).
:- mode map__contains(in, in) is semidet.

	% Search map for key.
:- pred map__search(map(K,V), K, V).
:- mode map__search(in, in, in) is semidet.	% implied
:- mode map__search(in, in, out) is semidet.

	% Search map for key, but abort if search fails.
:- pred map__lookup(map(K,V), K, V).
:- mode map__lookup(in, in, in) is semidet.	% implied
:- mode map__lookup(in, in, out) is det.

	% Search map for data.
:- pred map__inverse_search(map(K,V), V, K).
:- mode map__inverse_search(in, in, out) is nondet.

	% Insert a new key and corresponding value into a map.
	% Fail if the key already exists.
:- pred map__insert(map(K,V), K, V, map(K,V)).
:- mode map__insert(in, in, in, out) is semidet.

	% Insert a new key and corresponding value into a map.
	% Abort if the key already exists.
:- pred map__det_insert(map(K,V), K, V, map(K,V)).
:- mode map__det_insert(in, in, in, out) is det.

	% Update the value corresponding to a given key
	% Fail if the key doesn't already exist.
:- pred map__update(map(K,V), K, V, map(K,V)).
:- mode map__update(in, in, in, out) is semidet.

	% Update the value corresponding to a given key
	% Abort if the key doesn't already exist.
:- pred map__det_update(map(K,V), K, V, map(K,V)).
:- mode map__det_update(in, in, in, out) is det.

	% Update value if the key is already present, otherwise
	% insert new key and value.
:- pred map__set(map(K,V), K, V, map(K,V)).
:- mode map__set(in, in, in, out) is det.

	% Given a map, return a list of all the keys in the map
:- pred map__keys(map(K, _V), list(K)).
:- mode map__keys(in, out) is det.

	% Given a map, return a list of all the data values in the map
:- pred map__values(map(_K, V), list(V)).
:- mode map__values(in, out) is det.

	% convert a map to an association list
:- pred map__to_assoc_list(map(K,V), assoc_list(K,V)).
:- mode map__to_assoc_list(in, out) is det.

	% convert an association list to a map
:- pred map__from_assoc_list(assoc_list(K,V), map(K,V)).
:- mode map__from_assoc_list(in, out) is det.

	% convert a sorted association list to a map
:- pred map__from_sorted_assoc_list(assoc_list(K,V), map(K,V)).
:- mode map__from_sorted_assoc_list(in, out) is det.

	% delete a key-value pair from a map
	% if the key is not present, leave the map unchanged
:- pred map__delete(map(K,V), K, map(K,V)).
:- mode map__delete(in, in, out) is det.

	% delete a key-value pair from a map and return the value.
	% fail if the key is not present
:- pred map__remove(map(K,V), K, V, map(K,V)).
:- mode map__remove(in, in, out, out) is semidet.

	% delete a key-value pair from a map and return the value.
	% abort if the key is not present
:- pred map__det_remove(map(K,V), K, V, map(K,V)).
:- mode map__det_remove(in, in, out, out) is det.

	% Count the number of elements in the map.
:- pred map__count(map(K, V), int).
:- mode map__count(in, out) is det.

	% Convert a pair of lists (which must be of the same length)
	% to a map.
:- pred map__from_corresponding_lists(list(K), list(V), map(K, V)).
:- mode map__from_corresponding_lists(in, in, out) is det.

	% For map__merge(MapA, MapB, Map), MapA and MapB must
	% not both contain the same key.
:- pred map__merge(map(K, V), map(K, V), map(K, V)).
:- mode map__merge(in, in, out) is det.

	% For map__overlay(MapA, MapB, Map), if MapA and MapB both
	% contain the same key, then Map will map that key to
	% the value from MapB.  In otherwords, MapB takes precedence
	% over MapA.
:- pred map__overlay(map(K,V), map(K,V), map(K,V)).
:- mode map__overlay(in, in, out) is det.

	% map__select takes a map and a set of keys and returns
	% a map containing the keys in the set and their corresponding
	% values.
:- pred map__select(map(K,V), set(K), map(K,V)).
:- mode map__select(in, in, out) is det.

	% Given a list of keys, produce a list of their corresponding
	% values in a specified map.
:- pred map__apply_to_list(list(K), map(K, V), list(V)).
:- mode map__apply_to_list(in, in, out) is det.

	% Declaratively, a NOP.
	% Operationally, a suggestion that the implemention
	% optimize the representation of the map in the expectation
	% of a number of lookups but few or no modifications.
:- pred map__optimize(map(K, V), map(K, V)).
:- mode map__optimize(in, out) is det.

%-----------------------------------------------------------------------------%

:- import_module tree234.

:- type map(K,V)	==	tree234(K,V).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

%-----------------------------------------------------------------------------%

map__init(M) :-
	tree234__init(M).

map__is_empty(M) :-
	tree234__init(M).

map__contains(Map, K) :-
	map__search(Map, K, _).

:- map__search(_Map, K, _V) when K.	% required by bimap.nl

map__search(Map, K, V) :-
	tree234__search(Map, K, V).

:- map__lookup(_Map, K, _V) when K.	% required by bimap.nl

map__lookup(Map, K, V) :-
	( tree234__search(Map, K, V1) ->
		V = V1
	;
		error("map__lookup: key not found")
	).

map__insert(Map0, K, V, Map) :-
	tree234__insert(Map0, K, V, Map).
 
map__det_insert(Map0, K, V, Map) :-
	( tree234__insert(Map0, K, V, Map1) ->
		Map = Map1
	;	
		error("map__det_insert: key already present")
	).
 
map__update(Map0, K, V, Map) :-
	tree234__update(Map0, K, V, Map).

map__det_update(Map0, K, V, Map) :-
	( tree234__update(Map0, K, V, Map1) ->
		Map = Map1
	;	
		error("map__det_update: key not found")
	).

map__set(Map0, K, V, Map) :-
	tree234__set(Map0, K, V, Map).

map__keys(Map, KeyList) :-
	tree234__keys(Map, KeyList).

map__values(Map, KeyList) :-
	tree234__values(Map, KeyList).

map__to_assoc_list(M, L) :-
	tree234__tree234_to_assoc_list(M, L).

map__from_assoc_list(L, M) :-
	tree234__assoc_list_to_tree234(L, M).

map__from_sorted_assoc_list(L, M) :-
	tree234__assoc_list_to_tree234(L, M).

map__delete(Map0, Key, Map) :-
	tree234__delete(Map0, Key, Map).

map__remove(Map0, Key, Value, Map) :-
	tree234__remove(Map0, Key, Value, Map).

map__det_remove(Map0, Key, Value, Map) :-
	( tree234__remove(Map0, Key, Value1, Map1) ->
		Value = Value1,
		Map = Map1
	;
		error("map__det_remove: key not found")
	).

map__count(Map, Count) :-
	tree234__count(Map, Count).

%-----------------------------------------------------------------------------%

	% XXX innefficient

map__inverse_search(Map, V, K) :-
	tree234__tree234_to_assoc_list(Map, AssocList),
	assoc_list_member(K, V, AssocList).

%-----------------------------------------------------------------------------%

	% The code here is deliberately written using very simple
	% modes.
	% The reason we don't just use member/2 is that we want to
	% bootstrap this thing ASAP.

:- pred assoc_list_member(K, V, list(pair(K,V))).
:- mode assoc_list_member(in, out, in) is nondet.
:- mode assoc_list_member(out, in, in) is nondet.
:- mode assoc_list_member(in, in, in) is semidet.
assoc_list_member(K, V, [K - V | _]).
assoc_list_member(K, V, [_ | Xs]) :-
	assoc_list_member(K, V, Xs).

%-----------------------------------------------------------------------------%

map__from_corresponding_lists(Keys, Values, Map) :-
	assoc_list__from_corresponding_lists(Keys, Values, AssocList),
	tree234__assoc_list_to_tree234(AssocList, Map).

%-----------------------------------------------------------------------------%

map__merge(M0, M1, M) :-
	map__to_assoc_list(M0, ML0),
	map__to_assoc_list(M1, ML1),
	list__merge(ML0, ML1, ML),
	map__from_sorted_assoc_list(ML, M).

%-----------------------------------------------------------------------------%

map__optimize(Map, Map).

%-----------------------------------------------------------------------------%

map__overlay(Map0, Map1, Map) :-
	map__to_assoc_list(Map1, AssocList),
	map__overlay_2(AssocList, Map0, Map).

:- pred map__overlay_2(assoc_list(K,V), map(K,V), map(K,V)).
:- mode map__overlay_2(in, in, out) is det.

map__overlay_2([], Map, Map).
map__overlay_2([K - V | AssocList], Map0, Map) :-
	map__set(Map0, K, V, Map1),
	map__overlay_2(AssocList, Map1, Map).
	
%-----------------------------------------------------------------------------%

map__select(Original, KeySet, NewMap) :-
	set__to_sorted_list(KeySet, KeyList),
	map__init(NewMap0),
	map__select_2(KeyList, Original, NewMap0, NewMap).

:- pred map__select_2(list(K), map(K,V), map(K,V), map(K,V)).
:- mode map__select_2(in, in, in, out) is det.

map__select_2([], _Original, New, New).
map__select_2([K|Ks], Original, New0, New) :-
	(
		map__search(Original, K, V)
	->
		map__set(New0, K, V, New1)
	;
		New1 = New0
	),
	map__select_2(Ks, Original, New1, New).

%-----------------------------------------------------------------------------%

map__apply_to_list([], _, []).
map__apply_to_list([K | Ks], Map, [V | Vs]) :-
	map__lookup(Map, K, V),
	map__apply_to_list(Ks, Map, Vs).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
