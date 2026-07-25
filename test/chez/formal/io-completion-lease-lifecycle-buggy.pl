% Buggy controls for completion/lease lifecycle.
%
% One edge treats a cancellation request as permission to release and reuse a
% buffer before a terminal outcome. Another permits a second terminal
% publication. Both witnesses are reachable within four transitions.

edge(created, submitted).
edge(submitted, success_released).
edge(submitted, cancel_requested).
edge(cancel_requested, cancel_requested_but_released).
edge(cancel_requested, cancel_released).
edge(cancel_released, cancelled).
edge(success_released, succeeded).
edge(succeeded, double_published).

attrs(created, false, 0, false).
attrs(submitted, true, 0, false).
attrs(cancel_requested, true, 0, false).
attrs(cancel_requested_but_released, false, 0, true).
attrs(cancel_released, false, 0, false).
attrs(cancelled, false, 1, true).
attrs(success_released, false, 0, false).
attrs(succeeded, false, 1, true).
attrs(double_published, false, 2, true).

reach_in(0, State, State, [State]).
reach_in(N, From, To, [From|Path]) :-
    N > 0,
    edge(From, Next),
    N1 is N - 1,
    reach_in(N1, Next, To, Path).

reachable_within_four(State, Path) :-
    between(0, 4, N),
    reach_in(N, created, State, Path).

premature_reuse(State, Path) :-
    reachable_within_four(State, Path),
    attrs(State, _, 0, true).

double_publication(State, Path) :-
    reachable_within_four(State, Path),
    attrs(State, _, Publications, _),
    Publications > 1.
