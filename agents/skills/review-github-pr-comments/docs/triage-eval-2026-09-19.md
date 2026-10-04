# Evaluation: is `scripts/triage.mjs` (Jev triage) worth its place in the workflow?

Date: 2026-09-19. Evaluator: pi session, picking up `/tmp/handoff-triage-script-eval.md`.
Ground-truth PR: prefapp/gitops-k8s#2697 (3 Copilot threads, manually verdicted).

## Verdict

**Keep it — but reposition it.** The script's conservative policy works as
designed: across every observed run (3 handoff runs + 9 runs this session,
~36 judged threads), it **never auto-accepted a wrong verdict**. Everything
uncertain escalates, and escalation is always the safe outcome. Its real,
demonstrated value is narrower than "triage assistant", though:

1. **Re-review reaping** — detecting that already-fixed threads are fixed
   (saves the most tedious manual check in second+ review rounds).
2. **Noise filtering** — praise / withdrawn requests are auto-closed
   reliably in probes.
3. **Evidence pre-assembly** — even for escalated threads, the agent gets
   the thread, the anchored code excerpt, and the nearby hunks in one blob.

Its **suggestions on escalated threads are weak priors and were 0/2 wrong on
the ground-truth PR** — both times because the deciding evidence was outside
the script's evidence model, not because of bad reasoning. The skill's
contract ("input, never the verdict") is load-bearing; keep it.

## Verification of this session's two fixes (handoff said verify, don't re-fix)

| Fix | Check | Result |
|---|---|---|
| Repo detection (`gh repo view --json owner,name`) | Live run from the repo on the PR branch | PASS — GraphQL + diff fetch clean, 3 resolved threads skipped, exit 0 |
| Coordinate system (`git show <headRefOid>:<path>`) | Fixture with `headRefOid` set + discriminating probe | PASS — see below |

Coordinate-fix probes (run from the repo root):

- Path exists in working tree but **not at the commit** (untracked `app.log`,
  headRefOid=4c96d48a): `current_code` = "(file not available…)". Old code
  would have read the working-tree file. Correct new behavior.
- Commit **not fetched locally** (bogus oid): falls back to working tree.
- Path absent at commit (deleted by PR) returns no excerpt, by design.
- Cosmetic: the "(file not available in the local checkout)" message is now
  sometimes wrong — it can also mean "absent at the PR head commit".

## Experiments and findings

### E1 — Same-input stability: good (5 runs, augmented pre-fix fixture)

Fixture `/tmp/fixture.json` + `headRefOid=4c96d48a` (post-fix code via
`git show`, but the fixture's *pre-fix* diff). 5 identical runs:

| thread | actionable | addressed | decision (conf) | choice flips |
|---|---|---|---|---|
| mutationCommands:255 | 0.83–0.88 | 0.70–0.75 | already_handled (0.88–0.92) | 0/5 |
| mutationWorkflow:324 | 0.96–0.97 | 0.07–0.09 | fix (0.69–0.73) | 0/5 |
| RULES.md:120 | 0.77–0.83 | 0.05–0.06 | fix (0.48–0.58) | 0/5 |

Noul noise ≈ ±0.03; no choice flips. **The handoff's "confidence
instability" was across *changing evidence* (pre-fix → mid-fix → post-fix),
which is desired behavior, not a defect.**

### E3 — The real instability is the *policy outcome* at the threshold

Same fixture but with the coherent post-fix `gh pr diff` swapped in. 3
identical runs, thread 1 (genuinely fixed, fix within the ±40-line window):

| run | addressed | outcome |
|---|---|---|
| 1 | **0.80** | AUTO already_handled |
| 2 | 0.74 | escalate |
| 3 | 0.79 | escalate |

A genuinely-fixed thread's `already_addressed` noul **clusters exactly at the
0.8 gate** (0.72–0.80 across all 8 post-fix runs). The choice is stable and
correct (already_handled, conf ≈ 0.9); the *auto/escalate decision flaps on
identical input*. Two consequences:

- Effort saving is unpredictable run-to-run.
- The gate has **no safety margin**: a *wrong* already_handled with similar
  evidence strength would flap *into* auto-accept with the same coin-flip
  probability. No false auto observed yet, but n is small and the mechanism
  that would catch it (margin) is absent.

Side observation: the stale diff cost ~0.06–0.08 on `already_addressed`
(E1 vs E3) — enough to flip the gate. **Evidence-assembly correctness is
security-critical for the auto policy, and evidence assembly has no tests.**

### E2 — Noise-gate probes: no failure produced (synthetic threads, ground truth by construction)

Anchored on `packages/fs-forge-cli/src/help.ts` at 4c96d48a:

| thread | phrasing | actionable | outcome | correct? |
|---|---|---|---|---|
| Genuine concern (cached command-class mutation) | question + suggested fix | 0.92 | escalate | ✓ |
| Same concern | softer question, **no** suggested fix | 0.81 | escalate | ✓ |
| Praise ("LGTM") | — | 0.03 | AUTO noise | ✓ |
| Withdrawn request (2-comment thread) | — | 0.06 | AUTO noise | ✓ |

The `actionable < 0.5 → noise` gate survived both question phrasings. I could
not produce a false-noise auto. Residual structural concern stands: the gate
has zero margin (a single noul at a 0.5 cut, vs. the double 0.8 gate for
already_handled), and a false noise verdict **silently drops real feedback** —
the worst failure mode this script has. Also note Jev follows the "judge the
thread's current ask" instruction correctly (withdrawn case).

### Evidence-model adequacy (confirmed, now quantified)

- **Diff-hunk evidence was header-only (latent bug, found while testing this
  eval)**: the hunk regex `/^@@ [\s\S]*?(?=^@@|$)/gm` stops at the first
  multiline `$`, so Jev received only `@@ … @@` header lines — never diff
  content. The E1-vs-E3 delta (~0.06–0.08 on `addressed`) therefore reflects
  hunk *header* differences only. Thread 2's "filtered out by proximity"
  finding was confounded: its tests were invisible partly due to the ±60-line
  filter but mostly because *no* diff content was shown at all. Fixed — see
  "Updates applied" below.
- **±40-line excerpt window**: thread 2's fix sits ~120 lines from the
  anchor. "Add coverage" comments — the most common bot-comment category —
  can only be verified via diff evidence, never via the anchor excerpt.
- **Repo-wide scope**: thread 3's deciding evidence (release-please manifest
  mode + `BREAKING CHANGE:` footer) is unreachable by construction; Jev
  suggests fix (conf ~0.5) forever. Escalation contains it, but the
  suggestion is wrong and could anchor a tired agent.
- Both blind spots fail in the **safe direction** (escalate, not wrong auto).

## Effort accounting

- Pre-fix state (3 valid threads): 0 auto, 3 escalations with correct
  fix-suggestions. Savings ≈ 0; suggestions mildly useful.
- Post-fix state: 0–1 of 3 auto (flaps). Savings ≈ 1 thread's re-check.
- Projected best case: noisy re-review rounds (many stale/already-fixed/praise
  threads) — exactly where manual triage is most tedious and error-prone.
- Projected worst case: a fresh PR where every bot comment is a new valid
  issue — savings 0, plus a small anchoring tax on each escalated thread.
- Cost/latency: negligible (one request per thread, 6-way pool; a 3-thread
  run is a few seconds).

## Recommendations (small, ordered)

1. **Add margin to the noise gate.** Auto-noise only when `actionable < 0.2`
   (keep 0.2–0.5 escalated, labelled "likely noise"). Asymmetric strictness
   with the already_handled gate is currently backwards: the silently-fatal
   verdict has the weaker gate.
2. **Decide the already_handled gate on data, not vibes.** Log
   `decision.confidence`/`addressed` pairs over real PRs for a few weeks,
   then either move the threshold off the observed correct-cluster
   (0.72–0.80) or drop the `addressed` second gate and require higher choice
   confidence. Today the gate mostly produces flapping, not safety.
3. **Cheap evidence win for the coverage blind spot**: when `decision` is
   already_handled/fix but `addressed < 0.5`, or the thread text mentions
   test/coverage files, include the whole file's diff hunks (the diff is
   already local; the 3000-char cap still applies) instead of only
   anchor-near hunks. Would have fixed thread 2's verdict.
4. **Cheap evidence win for the scope blind spot**: include the branch's
   commit subjects/bodies (`git log` of the PR) in state — would have made
   thread 3's `BREAKING CHANGE:` footer visible. Does not solve
   tooling/convention evidence (release-please mode), which stays a
   documented ceiling.
5. **Add golden tests.** The two bugs this session were found by running,
   not testing — and E1/E3 show verdict quality *is* evidence-assembly
   quality. Fixture mode is already a harness: the fixtures from this eval
   (`/tmp/fixture*.json`, worth copying into `scripts/testdata/`) give
   regression tests for skip logic, excerpt coordinates (the `app.log`
   probe), and policy boundaries with canned answers.
6. **Keep escalation suggestions visually weak** in the markdown report (they
   were 0/2 on the ground-truth PR). The current output already prints the
   full distribution; do not "simplify" it to the top choice.

## Updates applied (2026-09-19, same day, after the eval above)

Applied the recommendations; all validated against the preserved fixtures
(`scripts/testdata/`), 19-test golden suite green (`npm test` in `scripts/`):

1. **Noise gate margin** — auto-noise now requires `actionable < 0.2`
   (`NOISE_THRESHOLD`); the 0.2–0.5 band escalates. Tests lock the boundary.
2. **Hunk-regex bug fixed** — `splitHunks()` replaces the header-only regex;
   hunks are ordered by distance to the anchor (near first) and fill the
   3000-char budget instead of dropping far hunks.
3. **Commit messages in state** — `pr.commits` carries subject+body of the
   PR's commits (`git log merge-base..head`), making `BREAKING CHANGE:`
   footers and similar process evidence visible to Jev.
4. **Testability refactor** — pure functions exported; `main()` guarded by an
   entrypoint check (with `realpathSync` on `argv[1]` — the skills dir is a
   dotfiles symlink, which broke the naive comparison). `--json` now includes
   per-thread `state`.
5. **Golden tests** — `scripts/triage.test.mjs` (node:test, hermetic: temp
   git repo for excerpt coordinates, policy-gate boundaries, skip logic,
   hunk ordering). The hunk test caught finding #2.
6. **SKILL.md** — step 4 now states Jev's evidence ceiling explicitly.

Not applied: already_handled threshold retuning (recommendation 2) — needs
logged real-PR data first; the threshold flap is documented instead.

### Post-fix validation (full-evidence fixture: post-fix code + post-fix diff + commits)

| thread | before fixes (E3, 3 runs) | after fixes (3 runs) | policy outcome |
|---|---|---|---|
| 1 (fixed, near anchor) | addressed 0.74–0.80, flapped auto/escalate | addressed **0.92–0.93**, conf 0.96–0.97 | **auto already_handled, 3/3 — no flap** |
| 2 (fixed, 120 lines away) | fix (conf 0.71–0.76) — wrong suggestion | **already_handled** (conf 0.37–0.42, addressed 0.45–0.50) | escalate, suggestion now right |
| 3 (evidence = commit footer) | fix (conf 0.51–0.58) | fix at conf **0.27–0.31**, addressed 0.07 | escalate, appropriately unsure |

Thread 1 stopped straddling the gate once the diff evidence was actually
present — most of the observed "threshold flapping" was starving evidence,
not a mis-set threshold. Thread 2's suggestion flipped to correct because
the added tests now reach the model. Thread 3's collapse in fix-confidence
shows the commit-message evidence registering (ground truth: not a code fix).

## Reproduction notes

- Debug harness used for state inspection: `/tmp/triage-debug/triage.mjs`
  (one-line patch to include `state` in `--json` output). Upstreamed:
  `--json` now always includes `state`.
- Preserved fixtures: `scripts/testdata/` (see its README). Working copies in
  `/tmp/fixture*.json`; post-fix diff `/tmp/diff-2697-head.patch`.
- Never print `TYPESAFE_API_KEY`; the script correctly reads it only from env.
