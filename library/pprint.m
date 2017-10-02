%---------------------------------------------------------------------------%
% vim:ts=4 sw=4 expandtab tw=0 wm=0 ft=mercury
%---------------------------------------------------------------------------%
% Copyright (C) 2000-2007, 2010-2011 The University of Melbourne
% Copyright (C) 2014-2017 The Mercury team.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: pprint.m
% Main author: rafe
% Stability: medium
%
% NOTE: this module has now been superceded by pretty_printer.m which is
% more economical, produces better output, has better control over
% the amount of output produced, and supports user-specifiable formatting
% for arbitrary types.
%
% ABOUT
% -----
%
% This started off as pretty much a direct transliteration of Philip Wadler's
% Haskell pretty printer described in "A Prettier Printer", available at
% http://cm.bell-labs.com/cm/cs/who/wadler/topics/recent.html
%
% Several changes have been made to the algorithm to preserve linear running
% time under a strict language and to ensure scalability to extremely large
% terms without thrashing the VM system.
%
% Wadler's approach has three main advantages:
%
% 1. the layout algebra is small and quite intuitive (more so than Hughes');
% 2. the pretty printer is optimal in the sense that it will never generate
%    output that over-runs the specified width unless that is unavoidable; and
% 3. the pretty printer is bounded in that it never needs to look more than
%    k characters ahead to make a formatting decision.
%
% I have made the following changes:
%
% (a) rather than having group/1 as a non-primitive function (for
% allowing line-breaks to be converted into spaces at the pretty
% printer's discretion) over docs, I have extended the doc type to
% include a `GROUP' constructor and made the appropriate algorithmic
% changes. Because `UNION' only arises as a consequence of processing
% a 'GROUP' it turns out to be simpler to do away with `UNION'
% altogether and convert clauses that process `UNION' terms to
% processing `GROUP's.
%
% (b) Flattened `line' breaks become empty strings rather than spaces.
%
% (c) The third change is the introduction of the `LABEL' constructor,
% which acts much like `NEST', except that indentation is defined
% using a string rather than a number of spaces. This is useful for,
% e.g., multi-line compiler errors and warnings that should be
% prefixed with the offending source file and line number.
%
% (d) The formatting decision procedure has been altered to preserve
% linear runtime behaviour in a strict language.
%
% (e) Naively marking up a term as a doc has the drawback that the
% resulting doc is significantly larger than the original term.
% Worse, any sharing structure in the original term leads to
% duplicated sub-docs, which can cause an exponential blow-up in the
% size of the doc w.r.t. the source term. To get around this problem
% I have introduced the 'DOC' constructor which causes on-demand
% conversion of arguments.
%
% [This is not true laziness in the sense that the 'DOC', once
% evaluated, will be overwritten with its value. This approach would
% lead to garbage retention and not solve the page thrashing behaviour
% otherwise experienced when converting extremely large terms.
% Instead, each 'DOC' is reevaluated each time it is examined.
% This trades off computation time for space.]
%
% I have added several obvious general purpose formatting functions.
%
%
% USAGE
% -----
%
% There are two stages in pretty printing an object of some type T:
% 1. convert the object to a pprint.doc using the constructor functions
%    described below or by simply calling pprint.to_doc/[1,2];
% 2. call pprint.write/[4,5] or pprint.to_string/2 passing the display width
%    and the doc.
%
%
% EXAMPLES
% --------
%
% The doc/1 type class has types string, char, int, float and doc as instances.
% Hence these types can all be converted to docs by applying doc/1.
% This happens automatically to the arguments of ++/2. Users may find it
% convenient to add other types as instances of the doc/1 type class.
%
% Below are some docs followed by the ways they might be displayed by the
% pretty printer given various line widths.
%
% 1. "Hello " ++ line ++ "world"
%
%   Hello
%   world
%
% 2. group("Hello " ++ line ++ "world")
%
%   Hello world
%
%   Hello
%   world
%
% 3. group("Hello " ++ nest(3, line ++ "world"))
%
%   Hello world
%
%   Hello
%      world
%
% 4. group("Goodbye " ++ nest(3, line ++ "cruel " ++ line ++ "world")
%
%   Goodbye cruel world
%
%   Goodbye
%      cruel
%      world
%
% 5. group("Goodbye " ++ nest(3, line ++ group("cruel " ++ line ++ "world")))
%
%   Goodbye cruel world
%
%   Goodbye
%      cruel world
%
%   Goodbye
%      cruel
%      world
%
% 6. label("Look! ", line ++
%                    group("Goodbye " ++
%                          nest(3, line ++ group("cruel " ++ line ++ "world"))))
%
%   Look! Goodbye cruel world
%
%   Look! Goodbye
%   Look!    cruel world
%
%   Look! Goodbye
%   Look!    cruel
%   Look!    world
%
%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- module pprint.
:- interface.

:- import_module char.
:- import_module io.
:- import_module list.
:- import_module stream.
:- import_module string.
:- import_module univ.

%---------------------------------------------------------------------------%

    % Clients must translate data structures into docs for
    % the pretty printer to display.
    %
:- type doc.

    % This typeclass can be used to simplify the construction of docs.
    %
:- typeclass doc(T) where [
    % Convert a T to a doc, placing a limit on how much of the term
    % will be fully converted as follows:
    %
    % doc(_, f         ) = f
    % doc(N, f(A, B, C)) = f/3 if N =< 0
    % doc(N, f(A, B, C)) = some representation of the term whereby
    %   A is converted as doc(N - 1, A),
    %   B is converted as doc(N - 2, B), and
    %   C is converted as doc(N - 3, C)
    %   - if there are more than N arguments, the N+1th and subsequent
    %     arguments should be replaced with a single ellipsis.
    %
    func doc(int, T) = doc
].

:- instance doc(doc).
:- instance doc(string).
:- instance doc(int).
:- instance doc(int8).
:- instance doc(int16).
:- instance doc(int32).
:- instance doc(uint).
:- instance doc(uint8).
:- instance doc(uint16).
:- instance doc(uint32).
:- instance doc(float).
:- instance doc(char).

    % Fully convert an instance of doc/1.
    %
:- func doc(T) = doc <= (doc(T)).

    % An alternative to the <>/2 concatenation operator that works
    % on members of the doc/1 typeclass.
    %
:- func T1 ++ T2 = doc <= (doc(T1), doc(T2)).

    % The empty document corresponding to the null string.
    %
:- func nil                 = doc.

    % The document consisting of a single string.
    %
    % NOTE: since string is now an instance of the doc/1
    % type class, it is simpler to just apply the doc/1
    % method.
    %
:- func text(string)        = doc.

    % The composition of two docs with no intervening space.
    %
    % NOTE: with the addition of the doc/1 type class, it is
    % simpler to construct compound docs using ++/2.
    %
:- func doc `<>` doc        = doc.

    % The newline document. In a group doc (see below) the pretty printer
    % may choose to instead `flatten' all line docs into nil docs in order
    % to fit a doc on a single line.
    %
:- func line                = doc.

    % Any `line' docs in the body that are not flattened out by the
    % pretty printer are followed by the given number of spaces
    % (nested `nest's add up).
    %
:- func nest(int, T)        = doc <= (doc(T)).

    % Identical to a nest doc except that indentation is extended with
    % a string label rather than some number of spaces.
    %
:- func label(string, T)    = doc <= (doc(T)).

    % A group doc gives the pretty printer a choice: if the doc can be printed
    % without line wrapping then it does so (all line, label, nest and group
    % directives within the group are ignored); otherwise the pretty printer
    % treats the group body literally, although nested group docs remain as
    % choice points.
    %
:- func group(T)            = doc <= (doc(T)).

    % This function can be used to convert strings, chars, ints and floats
    % to their text doc equivalents.
    %
    % NOTE: since these types are now instances of the doc/1 type class,
    % it is simpler to just apply the doc/1 method to these types.
    %
:- func poly(string.poly_type) = doc.

    % Shorthand for doc ++ line ++ doc.
    %
:- func doc `</>` doc       = doc.

    % Various bracketing functions.
    %
    %   bracketed(L, R, Doc) = L ++ Doc ++ R
    %       parentheses(Doc) = bracketed("(", ")", Doc)
    %          brackets(Doc) = bracketed("[", "]", Doc)
    %            braces(Doc) = bracketed("{", "}", Doc)
    %
:- func bracketed(T1, T2, T3)  = doc <= (doc(T1), doc(T2), doc(T3)).
:- func parentheses(T)         = doc <= (doc(T)).
:- func brackets(T)            = doc <= (doc(T)).
:- func braces(T)              = doc <= (doc(T)).

    % packed(Sep, [X1, X2, .., Xn]) = G1 `<>` G2 `<>` .. `<>` Gn where
    % Gi = group(line `<>` Xi `<>` Sep), except for Gn where
    % Gn = group(line `<>` Xn).
    %
    % For the singleton list case, packed(Sep, [X]) = group(line `<>` X).
    %
    % The resulting doc tries to pack as many items on a line as possible.
    %
:- func packed(T1, list(T2)) = doc <= (doc(T1), doc(T2)).

    % A variant of the above whereby only the first N elements of the list
    % are formatted and the rest are replaced by a single ellipsis.
    %
:- func packed(int, T1, list(T2)) = doc <= (doc(T1), doc(T2)).

    % packed_cs(Xs) = packed(comma_space, Xs).
    %
    % For example, to pretty print a Mercury list of docs one might use
    %
    %   brackets(nest(2, packed_cs(Xs)))
    %
:- func packed_cs(list(T)) = doc <= (doc(T)).

    % A variant of the above whereby only the first N elements of the list
    % are formatted and the rest are replaced by a single ellipsis.
    %
:- func packed_cs(int, list(T)) = doc <= (doc(T)).

    % This is like a depth-limited version of packed_cs/1 that first calls
    % to_doc/2 on each member of the argument list.
    %
:- func packed_cs_to_depth(int, list(T)) = doc.

    % This is like a version of packed_cs_to_depth/1 that first calls
    % univ_value/1 for each member of the argument list.
    %
:- func packed_cs_univ_args(int, list(univ)) = doc.

    % separated(PP, Sep, [X1,...,Xn]) =
    %   PP(X1) `<>` Sep `<>` ... Sep `<>` PP(Xn)
    %
:- func separated(func(T1) = doc, T2, list(T1)) = doc <= (doc(T2)).

    % Handy punctuation docs and versions with following
    % spaces and/or line breaks.
    %
:- func comma               = doc.
:- func semic               = doc.      % Semicolon.
:- func colon               = doc.
:- func space               = doc.
:- func comma_space         = doc.
:- func semic_space         = doc.
:- func colon_space         = doc.
:- func comma_line          = doc.
:- func semic_line          = doc.
:- func colon_line          = doc.
:- func space_line          = doc.
:- func comma_space_line    = doc.
:- func semic_space_line    = doc.
:- func colon_space_line    = doc.
:- func ellipsis            = doc.      % "...".

    % Performs word wrapping at the end of line, taking whitespace sequences
    % as delimiters separating words.
    %
    % See `char.is_whitespace' for the definition of whitespace characters
    % used by this predicate.
    %
:- func word_wrapped(string) = doc.

    % Convert arbitrary terms to docs. This requires std_util.functor/3 to work
    % on all components of the object being converted. The second version
    % places a maximum depth on terms which are otherwise truncated in the
    % manner described in the documentation for the doc/2 method of the doc/1
    % type class.
    %
    % This may throw an exception or cause a runtime abort if the term
    % in question has user-defined equality.
    %
:- func to_doc(T)           = doc.
:- func to_doc(int, T)      = doc.

    % Convert docs to pretty printed strings. The int argument specifies
    % a line width in characters.
    %
:- func to_string(int, doc) = string.

    % Write docs out in pretty printed format. The int argument specifies
    % a page width in characters.
    %
:- pred write(int::in, T::in, io::di, io::uo) is det <= doc(T).

    % Write docs to the specified string writer stream in pretty printed
    % format. The int argument specifies a page width in characters.
    %
:- pred write(Stream::in, int::in, T::in, State::di, State::uo) is det
    <= ( doc(T), stream.writer(Stream, string, State) ).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module array.
:- import_module deconstruct.
:- import_module enum.
:- import_module int.
:- import_module map.
:- import_module ops.
:- import_module pair.
:- import_module robdd.
:- import_module sparse_bitset.
:- import_module term.
:- import_module type_desc.
:- import_module version_array.

%---------------------------------------------------------------------------%

:- type doc
    --->    'NIL'
    ;       'SEQ'(doc, doc)
    ;       'NEST'(int, doc)
    ;       'LABEL'(string, doc)
    ;       'TEXT'(string)
    ;       'LINE'
    ;       'GROUP'(doc)
    ;       'DOC'(int, univ).
            %
            % 'DOC'(MaxDepth, Univ)
            % - Univ is the object to be converted to a doc via to_doc/3,
            %   represented as a univ.
            % - MaxDepth is the depth limit before using ellipsis.

    % This type is used to format key-value pairs in maps when
    % using the generic to_doc/[1,2] functions.
    %
:- type map_pair(K, V)
    --->    map_pair(K, V).

    % Used for depth-limit arguments.
    %
:- type depth == int.

%---------------------------------------------------------------------------%

doc(X) = doc(int.max_int, X).

%---------------------------------------------------------------------------%

:- instance doc(doc)    where [ doc(_, Doc)    = Doc            ].
:- instance doc(string) where [ doc(_, String) = text(String)   ].
:- instance doc(int)    where [ doc(_, Int)    = poly(i(Int))   ].
:- instance doc(int8)   where [ doc(_, Int8) = text(int8_to_string(Int8))].
:- instance doc(int16) where [ doc(_, Int16) = text(int16_to_string(Int16))].
:- instance doc(int32) where [ doc(_, Int32) = text(int32_to_string(Int32))].
:- instance doc(uint)   where [ doc(_, UInt) = text(uint_to_string(UInt))].
:- instance doc(uint8)  where [ doc(_, UInt8) = text(uint8_to_string(UInt8))].
:- instance doc(uint16) where [
    doc(_, UInt16) = text(uint16_to_string(UInt16))
].
:- instance doc(uint32) where [
    doc(_, UInt32) = text(uint32_to_string(UInt32))
].
:- instance doc(float)  where [ doc(_, Float)  = poly(f(Float)) ].
:- instance doc(char)   where [ doc(_, Char)   = poly(c(Char))  ].

%---------------------------------------------------------------------------%

Doc1 ++ Doc2 = doc(Doc1) `<>` doc(Doc2).

%---------------------------------------------------------------------------%

nil                     = 'NIL'.
X `<>` Y                = 'SEQ'(X, Y).
nest(I, X)              = 'NEST'(I, doc(X)).
label(L, X)             = 'LABEL'(L, doc(X)).
text(S)                 = 'TEXT'(S).
line                    = 'LINE'.
group(X)                = 'GROUP'(doc(X)).

poly(s(S))              = text(string.format("%s", [s(S)])).
poly(c(C))              = text(string.format("%c", [c(C)])).
poly(i(I))              = text(string.format("%d", [i(I)])).
poly(f(F))              = text(string.format("%f", [f(F)])).

%---------------------------------------------------------------------------%

to_string(W, X) = S :-
    layout_best(pred(H::in, T::in, [H | T]::out) is det, W, X, [], Ss),
    S = string.append_list(list.reverse(Ss)).

write(W, X, !IO) :-
    layout_best(io.write_string, W, doc(X), !IO).

write(Stream, W, X, !State) :-
    layout_best(put(Stream), W, doc(X), !State).

%---------------------------------------------------------------------------%

    % This is a contraction of Wadler's pretty, layout and be functions,
    % adapted to work with a strict evaluation order.
    %
:- pred layout_best(pred(string, T, T), int, doc, T, T).
:- mode layout_best(pred(in, di, uo) is det, in, in, di, uo) is det.
:- mode layout_best(pred(in, in, out) is det, in, in, in, out) is det.

layout_best(P, W, X, S0, S) :-
    lb(P, W, 0, _, "", X, S0, S).

    % lb(P, W, K0, K, I, X, S0, S)
    %
    %   P  is the predicate for accumulating output strings;
    %   W  is the number of characters on a line;
    %   K0 is the number of characters laid out on the current line so far;
    %   K  is the number of characters laid out on the current line after X;
    %   I  is the indentation string to appear after newlines;
    %   X  is the doc to lay out;
    %   S0 is the layout stream value before laying out X;
    %   S  is the resulting layout stream value after laying out X.
    %
    % This predicate is somewhat different to the function `be' described
    % by Wadler. In the first place, the decision procedure has been
    % recoded (in fits_flat/2) to preserve linear running times under
    % a strict language. The second important change is that lb/8
    % handles output strings as they are identified (e.g. writing them
    % out or accumulating them in a list), doing away with the need for
    % a more elaborate simple_doc type.
    %
:- pred lb(pred(string, T, T), int, int, int, string, doc, T, T).
:- mode lb(pred(in, di, uo) is det, in, in, out, in, in, di, uo) is det.
:- mode lb(pred(in, in, out) is det, in, in, out, in, in, in, out) is det.

lb(_, _, K,  K, _, 'NIL',         S,  S).

lb(P, W, K0, K, I, 'SEQ'(X, Y),   S0, S) :-
    lb(P, W, K0, K1, I, X, S0, S1),
    lb(P, W, K1, K,  I, Y, S1, S ).

lb(P, W, K0, K, I, 'NEST'(J, X),  S0, S) :-
    lb(P, W, K0, K, extend(I, J), X, S0, S).

lb(P, W, K0, K, I, 'LABEL'(L, X), S0, S) :-
    lb(P, W, K0, K, I ++ L, X, S0, S).

lb(P, _, _,  K, I, 'LINE',        S0, S) :-
    K = string.count_codepoints(I),
    P("\n", S0, S1),
    P(I,    S1, S ).

lb(P, W, K0, K, I, 'GROUP'(X),    S0, S) :-
    ( if fits_flat(X, W - K0) then layout_flat(P, K0, K, X, S0, S)
                              else lb(P, W, K0, K, I, X,  S0, S)
    ).

lb(P, W, K0, K, I, 'DOC'(D, U),   S0, S) :-
    lb(P, W, K0, K, I, to_doc(D, univ_value(U)), S0, S).

lb(P, _, K0, K, _, 'TEXT'(T),     S0, S) :-
    K = K0 + string.count_codepoints(T),
    P(T, S0, S).

%---------------------------------------------------------------------------%

    % Decide if a flattened doc will fit on the remainder of the line.
    %
:- pred fits_flat(doc::in, int::in) is semidet.

fits_flat(X, R) :-
    ff(X, R) = _.

:- func ff(doc, int) = int is semidet.

ff('NIL',         R) = R.
ff('SEQ'(X, Y),   R) = ff(Y, ff(X, R)).
ff('NEST'(_, X),  R) = ff(X, R).
ff('LABEL'(_, X), R) = ff(X, R).
ff('LINE',        R) = R.
ff('GROUP'(X),    R) = ff(X, R).
ff('DOC'(D, U),   R) = ff(to_doc(D, univ_value(U)), R).
ff('TEXT'(S),     R) = R - L :-
    L = string.count_codepoints(S),
    R > L.

%---------------------------------------------------------------------------%

    % Lay out a doc in its flattened form.
    %
:- pred layout_flat(pred(string, T, T), int, int, doc, T, T).
:- mode layout_flat(pred(in, di, uo) is det, in, out, in, di, uo) is det.
:- mode layout_flat(pred(in, in, out) is det, in, out, in, in, out) is det.

layout_flat(_, K,  K, 'NIL',         S,  S).

layout_flat(P, K0, K, 'SEQ'(X, Y),   S0, S) :-
    layout_flat(P, K0, K1, X, S0, S1),
    layout_flat(P, K1, K,  Y, S1, S ).

layout_flat(P, K0, K, 'NEST'(_, X),  S0, S) :-
    layout_flat(P, K0, K, X, S0, S).

layout_flat(P, K0, K, 'LABEL'(_, X), S0, S) :-
    layout_flat(P, K0, K, X, S0, S).

layout_flat(_, K,  K, 'LINE',        S,  S).

layout_flat(P, K0, K, 'GROUP'(X),    S0, S) :-
    layout_flat(P, K0, K, X, S0, S).

layout_flat(P, K0, K, 'DOC'(D, U),   S0, S) :-
    layout_flat(P, K0, K, to_doc(D, univ_value(U)), S0, S).

layout_flat(P, K0, K, 'TEXT'(T),     S0, S) :-
    K = K0 + string.count_codepoints(T),
    P(T, S0, S).

%---------------------------------------------------------------------------%

:- func extend(string, int) = string.

extend(I, J) = I ++ string.duplicate_char(' ', J).

%---------------------------------------------------------------------------%

X `</>` Y               = X ++ line ++ Y.

%---------------------------------------------------------------------------%

bracketed(L, R, D)      = L ++ D ++ R.
parentheses(D)          = bracketed("(", ")", D).
brackets(D)             = bracketed("[", "]", D).
braces(D)               = bracketed("{", "}", D).

%---------------------------------------------------------------------------%

separated(_,  _,   []) = nil.

separated(PP, Sep, [X | Xs]) =
    ( if Xs = [] then PP(X)
                 else PP(X) ++ (Sep ++ separated(PP, Sep, Xs))
    ).

%---------------------------------------------------------------------------%

packed(_N, _Sep, []           ) =
    nil.

packed(N,  _Sep, [X]          ) =
    group(line ++ (if 0 < N then doc(X) else ellipsis)).

packed(N,  Sep,  [X1, X2 | Xs]) =
    ( if   0 < N
      then group(line ++ X1 ++ Sep) ++ packed(N - 1, Sep, [X2 | Xs])
      else group(line ++ ellipsis)
    ).

%---------------------------------------------------------------------------%

packed(Sep, Xs) = packed(int.max_int, Sep, Xs).

%---------------------------------------------------------------------------%

packed_cs(N, Xs) = packed(N, ", ", Xs).

%---------------------------------------------------------------------------%

packed_cs(Xs) = packed(", ", Xs).

%---------------------------------------------------------------------------%

packed_cs_to_depth(Depth, Xs) =
    packed_cs(Depth, list.map(to_doc(Depth), Xs)).

%---------------------------------------------------------------------------%

packed_cs_univ_args(Depth, UnivArgs) =
    packed_cs(Depth, list.map(func(UA) = 'DOC'(Depth, UA), UnivArgs)).

%---------------------------------------------------------------------------%

word_wrapped(String) =
    packed(space, list.map(func(Word) = text(Word),
        string.words_separator(char.is_whitespace, String))).

%---------------------------------------------------------------------------%

comma                   = text(",").
semic                   = text(";").
colon                   = text(":").
space                   = text(" ").
comma_space             = text(", ").
semic_space             = text("; ").
colon_space             = text(": ").
comma_line              = "," ++ line.
semic_line              = ";" ++ line.
colon_line              = ":" ++ line.
space_line              = " " ++ line.
comma_space_line        = ", " ++ line.
semic_space_line        = "; " ++ line.
colon_space_line        = ": " ++ line.
ellipsis                = text("...").

%---------------------------------------------------------------------------%

to_doc(X) = to_doc(int.max_int, X).

%---------------------------------------------------------------------------%

    % Infix "," has precedence 1000 in standard Mercury.
    %
to_doc(Depth, X) = to_doc(Depth, 1000, X).

%---------------------------------------------------------------------------%

    % This may throw an exception or cause a runtime abort if the term
    % in question has user-defined equality.
    %
:- func to_doc(int, priority, T) = doc.

to_doc(Depth, Priority, X) =
    ( if      dynamic_cast_to_var(X, Var)
      then    var_to_doc(Depth, Var)

      else if dynamic_cast_to_sparse_bitset_of_int(X, SparseBitsetInt)
      then    sparse_bitset_to_doc(Depth, SparseBitsetInt)

      else if dynamic_cast_to_sparse_bitset_of_var(X, SparseBitsetVar)
      then    sparse_bitset_to_doc(Depth, SparseBitsetVar)

      else if dynamic_cast_to_list(X, List)
      then    list_to_doc(Depth, List)

      else if dynamic_cast_to_array(X, Array)
      then    array_to_doc(Depth, Array)

      else if dynamic_cast_to_version_array(X, VersionArray)
      then    version_array_to_doc(Depth, VersionArray)

      else if dynamic_cast_to_tuple(X, Tuple)
      then    tuple_to_doc(Depth, Tuple)

      else if dynamic_cast_to_map(X, Map)
      then    map_to_doc(Depth, Map)

      else if dynamic_cast_to_map_pair(X, MapPair)
      then    map_pair_to_doc(Depth, MapPair)

      else if dynamic_cast_to_robdd(X, Robdd)
      then    robdd_to_doc(Depth, Robdd)

      else    generic_term_to_doc(Depth, Priority, X)
    ).

%---------------------------------------------------------------------------%

:- func generic_term_to_doc(depth, priority, T) = doc.

generic_term_to_doc(Depth, Priority, X) = Doc :-
    ( if
        Depth =< 0
      then
        functor(X, canonicalize, Name, Arity),
        Doc = ( if Arity = 0 then text(Name) else Name ++ "/" ++ Arity )
      else
        deconstruct(X, canonicalize, Name, _Arity, UnivArgs),
        Table = init_mercury_op_table,
        Doc =
            ( if
                UnivArgs = [UnivArg],
                lookup_prefix_op(Table, Name, OpPri, Assoc)
              then
                maybe_parens(Priority, OpPri,
                    Name ++
                    space ++
                    univ_to_doc(Depth - 1, OpPri `adjusted_by` Assoc,
                        UnivArg)
                )
              else if
                UnivArgs = [UnivArg],
                lookup_postfix_op(Table, Name, OpPri, Assoc)
              then
                maybe_parens(Priority, OpPri,
                    univ_to_doc(Depth - 1, OpPri `adjusted_by` Assoc,
                        UnivArg) ++
                    space ++
                    Name
                )
              else if
                UnivArgs = [UnivArgL, UnivArgR],
                lookup_infix_op(Table, Name, OpPri, AssocL, AssocR)
              then
                maybe_parens(Priority, OpPri,
                    univ_to_doc(Depth - 1, OpPri `adjusted_by` AssocL,
                        UnivArgL) ++
                    space ++
                    Name ++
                    space ++
                    group(line ++
                        nest(2,
                            univ_to_doc(Depth - 2, OpPri `adjusted_by` AssocR,
                                UnivArgR)
                        )
                    )
                )
              else if
                UnivArgs = [UnivArgR1, UnivArgR2],
                lookup_binary_prefix_op(Table, Name, OpPri, AssocR1, AssocR2)
              then
                maybe_parens(Priority, OpPri,
                    Name ++
                    space ++
                    univ_to_doc(Depth - 2, OpPri `adjusted_by` AssocR1,
                        UnivArgR1) ++
                    space ++
                    group(line ++
                        nest(2,
                            univ_to_doc(Depth - 2, OpPri `adjusted_by` AssocR2,
                                UnivArgR2)
                        )
                    )
                )
              else if
                UnivArgs = []
              then
                text(Name)
              else
                group(
                    Name ++ parentheses(
                        nest(2, packed_cs_univ_args(Depth - 1, UnivArgs))
                    )
                )
            )
    ).

%---------------------------------------------------------------------------%

    % We need to put parentheses around a subterm if its top-level
    % functor has a higher priority than its parent functor.
    %
:- func maybe_parens(priority, priority, doc) = doc.

maybe_parens(ParentPriority, OpPriority, Doc) =
    ( if ParentPriority < OpPriority then parentheses(Doc) else Doc ).

%---------------------------------------------------------------------------%

    % An x priority adjustment lowers the effective priority by one.
    % A y priority adjustment does not affect the effective priority.
    %
:- func priority `adjusted_by` assoc = priority.

Priority `adjusted_by` x = Priority - 1.
Priority `adjusted_by` y = Priority.

%---------------------------------------------------------------------------%

    % Convert a univ encapsulated value into a doc.
    %
:- func univ_to_doc(int, priority, univ) = doc.

univ_to_doc(Depth, Priority, Univ) = to_doc(Depth, Priority, univ_value(Univ)).

%---------------------------------------------------------------------------%

:- some [T2] pred dynamic_cast_to_var(T1::in, var(T2)::out) is semidet.

dynamic_cast_to_var(X, V) :-
    % If X is a var then it has a type with one type argument.
    [ArgTypeDesc] = type_args(type_of(X)),

    % Convert ArgTypeDesc to a type variable ArgType.
    (_ : ArgType) `has_type` ArgTypeDesc,

    % Constrain the type of V to be var(ArgType) and do the cast.
    dynamic_cast(X, V : var(ArgType)).

%---------------------------------------------------------------------------%

:- pred dynamic_cast_to_sparse_bitset_of_int(T1::in, sparse_bitset(int)::out)
    is semidet.

dynamic_cast_to_sparse_bitset_of_int(X, A) :-
    dynamic_cast(X, A : sparse_bitset(int)).

:- some [T2] pred dynamic_cast_to_sparse_bitset_of_var(T1::in,
    sparse_bitset(var(T2))::out) is semidet.

dynamic_cast_to_sparse_bitset_of_var(X, A) :-
    dynamic_cast(X, A : sparse_bitset(var)).

%---------------------------------------------------------------------------%

:- some [T2] pred dynamic_cast_to_version_array(T1::in,
    version_array(T2)::out) is semidet.

dynamic_cast_to_version_array(X, VA) :-
    % If X is a version array then it has a type with one type argument.
    [ArgTypeDesc] = type_args(type_of(X)),

    % Convert ArgTypeDesc to a type variable ArgType.
    (_ : ArgType) `has_type` ArgTypeDesc,

    % Constrain the type of VA to be array(ArgType) and do the cast.
    dynamic_cast(X, VA : version_array(ArgType)).

%---------------------------------------------------------------------------%

:- some [T2] pred dynamic_cast_to_list(T1::in, list(T2)::out) is semidet.

dynamic_cast_to_list(X, L) :-
    % If X is a list then it has a type with one type argument.
    [ArgTypeDesc] = type_args(type_of(X)),

    % Convert ArgTypeDesc to a type variable ArgType.
    (_ : ArgType) `has_type` ArgTypeDesc,

    % Constrain the type of L to be list(ArgType) and do the cast.
    dynamic_cast(X, L : list(ArgType)).

%---------------------------------------------------------------------------%

:- some [T2, T3] pred dynamic_cast_to_map(T1::in, map(T2, T3)::out) is semidet.

dynamic_cast_to_map(X, M) :-
    % If X is a map then it has a type with two type arguments.
    [KeyTypeDesc, ValueTypeDesc] = type_args(type_of(X)),

    % Convert the TypeDescs to type variables.
    (_ : KeyType) `has_type` KeyTypeDesc,
    (_ : ValueType) `has_type` ValueTypeDesc,

    % Constrain the type of M to be map(KeyType, ValueType) and do the cast.
    dynamic_cast(X, M : map(KeyType, ValueType)).

%---------------------------------------------------------------------------%

:- some [T2, T3] pred dynamic_cast_to_map_pair(T1::in, map_pair(T2, T3)::out)
    is semidet.

dynamic_cast_to_map_pair(X, MP) :-
    % If X is a map_pair then it has a type with two type arguments.
    [KeyTypeDesc, ValueTypeDesc] = type_args(type_of(X)),

    % Convert the TypeDescs to type variables.
    (_ : KeyType) `has_type` KeyTypeDesc,
    (_ : ValueType) `has_type` ValueTypeDesc,

    % Constrain the type of MP to be map_pair(KeyType, ValueType)
    % and do the cast.
    dynamic_cast(X, MP : map_pair(KeyType, ValueType)).

%---------------------------------------------------------------------------%

:- pred dynamic_cast_to_tuple(T::in, T::out) is semidet.

dynamic_cast_to_tuple(X, X) :-
    % If X is a tuple then it's functor name is {}.
    functor(X, canonicalize, "{}", _Arity).

%---------------------------------------------------------------------------%

:- some [T2] pred dynamic_cast_to_robdd(T1, robdd(T2)).
:-           mode dynamic_cast_to_robdd(in, out) is semidet.

dynamic_cast_to_robdd(X, R) :-
    % If X is a robdd then it has a type with one type argument.
    [ArgTypeDesc] = type_args(type_of(X)),

    % Convert ArgTypeDesc to a type variable ArgType.
    (_ : ArgType) `has_type` ArgTypeDesc,

    % Constrain the type of R to be robdd(ArgType) and do the cast.
    dynamic_cast(X, R : robdd(ArgType)).

%---------------------------------------------------------------------------%

:- func var_to_doc(int, var(T)) = doc.

var_to_doc(Depth, V) =
    to_doc(Depth, to_int(V)).

%---------------------------------------------------------------------------%

    % XXX Ideally we'd just walk the sparse bitset. But that is an optimization
    % for another day.
    %
:- func sparse_bitset_to_doc(int, sparse_bitset(T)) = doc <= enum(T).

sparse_bitset_to_doc(Depth, A) =
    group("sparse_bitset" ++
        parentheses(list_to_doc(Depth - 1, sparse_bitset.to_sorted_list(A)))).

%---------------------------------------------------------------------------%

:- func list_to_doc(int, list(T)) = doc.

list_to_doc(Depth, Xs) =
    brackets(nest(1, packed_cs_to_depth(Depth - 1, Xs))).

%---------------------------------------------------------------------------%

    % XXX Ideally we wouldd just walk the array. But that is an optimization
    % for another day.
    %
:- func array_to_doc(int, array(T)) = doc.

array_to_doc(Depth, A) =
    group("array" ++ parentheses(list_to_doc(Depth - 1, array.to_list(A)))).

%---------------------------------------------------------------------------%

    % XXX Ideally we wouldd just walk the version array. But that is
    % an optimization for another day.
    %
:- func version_array_to_doc(int, version_array(T)) = doc.

version_array_to_doc(Depth, A) =
    group("version_array"
        ++ parentheses(list_to_doc(Depth - 1, version_array.to_list(A)))).

%---------------------------------------------------------------------------%

    % This should only really be used if the item in question really
    % is a tuple.
    %
:- func tuple_to_doc(int, T) = doc.

tuple_to_doc(Depth, Tuple) = Doc :-
    deconstruct(Tuple, canonicalize, _Name, _Arity, UnivArgs),
    Doc = group(braces(nest(1, packed_cs_univ_args(Depth - 1, UnivArgs)))).

%---------------------------------------------------------------------------%

:- func map_to_doc(int, map(T1, T2)) = doc.

map_to_doc(Depth, X) = Doc :-
    KVs = list.map(mk_map_pair, map.to_assoc_list(X)),
    Doc = group("map" ++ parentheses(list_to_doc(Depth - 1, KVs))).

:- func mk_map_pair(pair(K, V)) = map_pair(K, V).

mk_map_pair(K - V) = map_pair(K, V).

%---------------------------------------------------------------------------%

:- func map_pair_to_doc(int, map_pair(T1, T2)) = doc.

map_pair_to_doc(Depth, map_pair(Key, Value)) =
    to_doc(Depth - 1, Key) ++ text(" -> ") ++
        group(nest(2, line ++ to_doc(Depth - 1, Value))).

%---------------------------------------------------------------------------%

:- func robdd_to_doc(int, robdd(T)) = doc.

robdd_to_doc(Depth, R) =
    "robdd_dnf" ++ parentheses(list_to_doc(Depth - 1, dnf(R))).

%---------------------------------------------------------------------------%
