# Ledger

Goal: Add session expiry to the login flow. Smallest change: store an expiry timestamp on the server session record and reject expired tokens in auth middleware.

| Item       | Stage  | Status          | Subagent                                                                 | Worktree               |
| ---------- | ------ | --------------- | ------------------------------------------------------------------------ | ---------------------- |
| login-form | build  | running         | subagent-build-4123 window:7f3a                                          | ../app-wt/login (login) |
| session    | review | question        | subagent-review-4188 window:91c2 (spec); subagent-review-4190 window:c04e (standards) | ~/src/app (session)    |
| docs       | write  | done            | -                                                                        | ../app-wt/docs (docs)  |

## Decisions
- login-form: keep the legacy cookie name (user, 2026-10-04).
- session: expiry runs on the server clock, not the client (user, 2026-10-05).
