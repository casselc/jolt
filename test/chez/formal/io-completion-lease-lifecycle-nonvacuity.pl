% Non-vacuity control for the corrected completion/lease lifecycle.
%
% A valid cancellation path requires four distinct transitions. It keeps the
% lease through the request, ends native access before publication, and allows
% caller reuse only in the terminal cancelled state.

edge(created, submitted).
edge(submitted, cancel_requested).
edge(cancel_requested, cancel_released).
edge(cancel_released, cancelled).

attrs(created, false, 0, false).
attrs(submitted, true, 0, false).
attrs(cancel_requested, true, 0, false).
attrs(cancel_released, false, 0, false).
attrs(cancelled, false, 1, true).

reach_in(0, State, State, [State]).
reach_in(N, From, To, [From|Path]) :-
    N > 0,
    edge(From, Next),
    N1 is N - 1,
    reach_in(N1, Next, To, Path).

valid_cancel_path(Path) :-
    reach_in(4, created, cancelled, Path),
    attrs(submitted, true, 0, false),
    attrs(cancel_requested, true, 0, false),
    attrs(cancel_released, false, 0, false),
    attrs(cancelled, false, 1, true).
