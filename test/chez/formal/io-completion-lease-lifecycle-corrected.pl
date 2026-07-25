% Corrected completion/lease lifecycle, bounded to four transitions.
%
% attrs(State, NativeMayAccess, TerminalPublications, CallerMayReuse).
% Release states make native access false before terminal publication, while
% keeping caller reuse false until the terminal outcome is visible.

edge(created, submitted).
edge(submitted, success_released).
edge(submitted, failure_released).
edge(submitted, cancel_requested).
edge(cancel_requested, success_released).
edge(cancel_requested, failure_released).
edge(cancel_requested, cancel_released).
edge(success_released, succeeded).
edge(failure_released, failed).
edge(cancel_released, cancelled).

attrs(created, false, 0, false).
attrs(submitted, true, 0, false).
attrs(cancel_requested, true, 0, false).
attrs(success_released, false, 0, false).
attrs(failure_released, false, 0, false).
attrs(cancel_released, false, 0, false).
attrs(succeeded, false, 1, true).
attrs(failed, false, 1, true).
attrs(cancelled, false, 1, true).

reach_in(0, State, State, [State]).
reach_in(N, From, To, [From|Path]) :-
    N > 0,
    edge(From, Next),
    N1 is N - 1,
    reach_in(N1, Next, To, Path).

reachable_within_four(State, Path) :-
    between(0, 4, N),
    reach_in(N, created, State, Path).

bad(State, Path) :-
    reachable_within_four(State, Path),
    attrs(State, true, Publications, _),
    Publications > 0.
bad(State, Path) :-
    reachable_within_four(State, Path),
    attrs(State, _, 0, true).
bad(State, Path) :-
    reachable_within_four(State, Path),
    attrs(State, _, Publications, _),
    Publications > 1.
bad(cancel_requested, Path) :-
    reachable_within_four(cancel_requested, Path),
    attrs(cancel_requested, false, _, _).

valid_cancel_path(Path) :-
    reach_in(4, created, cancelled, Path),
    attrs(cancelled, false, 1, true).
