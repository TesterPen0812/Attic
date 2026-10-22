# Phase 3 owner decisions

2026-10-22, Round 2 review fixes: while a workspace operation reserves input,
queue plain typing and Return for the post-operation selection. Navigation,
focus traversal, Escape, scrolling and Copy pass through. Other mutations,
including the start of IME composition, refuse visibly and announce the reason.
The original reservation tests now cover these remaining refused mutations;
the `testOpusR4` regressions cover queued typing, Undo grouping and replacement.

The original review's finding 16 remains unchanged: a plain task-title click
opens its page, pending a separate product decision.
