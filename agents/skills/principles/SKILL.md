---
name: principles
description: Engineering principles for verification, root-cause debugging, stateful design, and code clarity. Loaded by Refine Subagents; also use when verifying work, tracing a bug or measurement, or simplifying hard-to-trace code.
---

# Engineering principles

Apply every principle that bears on the Work Item before sending a Completion report. Minimal-change discipline, subtracting dead weight first, and migrating callers before deleting legacy APIs are covered by `coding` and `zero-tech-debt`.

## Prove it works

Verify every output against the real artifact: run the feature, read the actual value, and inspect the diff. Proxies such as "it compiles", file mtimes, cached output, or self-reports hide broken behavior, and when a check fails, inspect the observation method before blaming the system. In Build and Refine, script the check when practical, run it against the real change, and cite the observed output in your report file before sending a Completion report.

## Fix root causes

Fix the fault at the first place the system went wrong rather than where the symptom surfaced. Reproduce first and trace until you find a wrong decision in code, instrumenting when stuck; handle legitimate triggering states where the code broke, and eliminate illegal states at their source instead of masking them with guards, retries, swallowed errors, or clamps. In Build, sweep sibling sites with the same fault, and note any cheap always-on signal that would have exposed a deep dig sooner (or send a Question if fixing the origin crosses Work Item scope).

## Attack the premise

When two or more fixes sharing one premise fail the same gate, suspect the premise instead of writing another fix. Write the shared assumption as one sentence, run an observation that would come out differently if it were false, and inspect how failures are distributed rather than only how large they are; fix what puts a component on the losing side instead of adding cleanup around it. In Build, pause after two failed attempts, test the premise directly, and send a Question to the Manager if disproving it changes the Work Item's plan.

## Sequence verifiable units

Break multi-step work such as sweeps, migrations, or repeated edits into small units that each end in a green check, and verify each unit before starting the next even when a tool makes the edits. Ordering work into verified brackets isolates regressions and makes history self-proving: failing test before fix, subtraction before reshape, baseline before treatment. On the Work Item branch, land each logical unit as a clean, green commit so Review Subagents can verify the diff in sequence.

## Build the lever

For non-trivial edits, migrations, analyses, or checks, build the smallest rerunnable script, codemod, or generator instead of working by hand. The bar is triviality rather than repetition: manual work is error-prone and cannot be audited, whereas a deterministic tool is an artifact a reviewer can rerun. In Build, do one unit by hand, prove the tool by rerunning it on that unit, keep it safe to rerun, and commit it when the work outlives the session.

## Make operations idempotent

Design every state-changing operation to converge to the target state regardless of retries, restarts, or partial prior runs. Derive each action from current state compared to the goal, make leftover artifacts such as locks, temp files, or partial records recognizable as stale, and write to a temporary path before renaming into place. When a Build Work Item touches install scripts, hooks, state files, or loops, test what happens if the operation runs twice or stops mid-way and add reconciliation where needed.

## Separate before serializing shared state

When concurrent actors write to the same file, branch, key, or state object, separate ownership first by giving each actor its own file, key, branch, or directory and merging on read. Shared mutation invites races even when writers touch different fields of one file, and prose instructions are not concurrency control. Mirror the workflow's own split (disjoint Work Items use separate worktrees and report files), and introduce structural serialization such as a lockfile, single writer, or compare-and-swap only when one shared writer is a real invariant.

## Explain the number

Before trusting, reporting, or acting on a measured number such as a speedup, regression, latency, or eval score, write the decision threshold and noise floor first and stop when run-to-run spread exceeds the effect. Name the actual limiter from a profile or counters ("why not double?") rather than a guess from reading code, and rule out confounders such as errors, cached or skipped work, and unexecuted paths. Whenever a Build or Refine report cites a measurement, include the run count, spread, and observed limiter so Review and the Manager can audit the claim.

## Minimize reader load

Reduce both axes of reader load: the layers a reader traces between question and answer, and the hidden or mutable state they must hold in mind. Inline single-caller wrappers, unused adapters, and pass-throughs, shrink state scope (returns over mutations, locals over fields, fields over globals, derive over sync), and enforce invariants once at the boundary. In Build and Refine, verify that a reader can answer "where does X come from?" and "what can change X?" in under 30 seconds.

## Encode lessons in structure

When you repeat an instruction or hit a recurring correction, encode the rule as a lint, type, metadata flag, runtime check, or test instead of adding more prose. Prose drifts and costs attention on every run; when a structural fix exists, keep only the structural fix, and reserve prominent instructions with a concrete failure example for lessons that genuinely require judgment. In Build and Refine, turn recurring Review findings into automated checks within scope, and note repo-wide structural fixes in your report.

---

Adapted from [pstack](https://github.com/cursor/plugins/tree/main/pstack) by Lauren "poteto" Tan, licensed under the MIT License.
