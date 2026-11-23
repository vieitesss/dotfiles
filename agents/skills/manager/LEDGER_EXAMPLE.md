# Ledger

Goal: Add session expiry to the login flow. Smallest change: store an expiry timestamp on the server session record and reject expired tokens in auth middleware.

<!-- Status cells stay at most 200 characters; put detail in the report and point to it. -->

| Item       | Stage  | Status                                  | Subagent                                                                             | Worktree                |
| ---------- | ------ | --------------------------------------- | ------------------------------------------------------------------------------------ | ----------------------- |
| login-form | build  | running                                 | subagent-build-4123 window:7f3a                                                      | ../app-wt/login (login) |
| session    | review | blocked on user; see Open questions     | subagent-review-4188 window:91c2 (spec); subagent-review-4190 window:c04e (standards) | ~/src/app (session)     |
| docs       | write  | done; see .agents/reports/docs-write.md | -                                                                                    | ../app-wt/docs (docs)   |

## Open questions to user

<!-- Write here before asking the user; remove once answered and move to Decisions. Check Decisions before asking. -->

- session: invalidate active tokens on password reset, or keep them until expiry? (asked 2026-10-05)

## Decisions

- login-form: keep the legacy cookie name (user, 2026-10-04).
- session: expiry runs on the server clock, not the client (user, 2026-10-05).

## Operations

<!-- Date each line and prune it when the fact stops holding. -->

- 2026-10-05: staging Redis flushes every night at 02:00 UTC; run expiry integration tests against local Docker Redis.
