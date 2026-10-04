// Golden tests for triage.mjs — hermetic: no network, no TYPESAFE_API_KEY,
// no gh. Run: npm test (node --test).
//
// The fixtures in testdata/ capture real PR threads for manual replay via
// --fixture; these tests lock the pure logic: policy gates, skip logic,
// excerpt coordinate behavior, and diff-hunk ordering. Verdict quality is
// evidence-assembly quality (docs/triage-eval-2026-09-19.md), so the
// evidence-assembly paths are the ones that matter most.

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

import {
  applyPolicy,
  buildState,
  clip,
  codeExcerpt,
  diffHunksNear,
  latestReviewerMessage,
  oneLine,
  prNumberFrom,
  renderMarkdown,
  toPoint,
  CAPS,
  CODE_CONTEXT_LINES,
  NOISE_THRESHOLD,
} from "./triage.mjs";

// ---------------------------------------------------------------- helpers

function answers({ actionable = 1, addressed = 0, choice = "fix", confidence = 0.9 } = {}) {
  return {
    actionable: { noul: actionable },
    already_addressed: { noul: addressed },
    decision: { choice, confidence, probabilities: { [choice]: confidence } },
  };
}

function thread(overrides = {}) {
  return {
    isResolved: false,
    isOutdated: false,
    path: "src/a.ts",
    line: 10,
    originalLine: 10,
    comments: {
      nodes: [
        { author: { login: "reviewer" }, body: "please change this", url: "u1", createdAt: "t1" },
      ],
    },
    ...overrides,
  };
}

// ---------------------------------------------------------------- small pure fns

test("prNumberFrom parses numbers and PR URLs, rejects garbage", () => {
  assert.equal(prNumberFrom("42"), 42);
  assert.equal(prNumberFrom("https://github.com/o/r/pull/137"), 137);
  assert.equal(prNumberFrom("abc"), null);
  assert.equal(prNumberFrom(null), null);
  assert.equal(prNumberFrom("-3"), null);
});

test("clip truncates with a marker", () => {
  assert.equal(clip("short", 10), "short");
  assert.equal(clip("", 10), "");
  const out = clip("x".repeat(100), 10);
  assert.ok(out.startsWith("x".repeat(10)));
  assert.ok(out.includes("[truncated]"));
});

test("oneLine flattens whitespace and truncates", () => {
  assert.equal(oneLine("a\n b\tc"), "a b c");
  assert.ok(oneLine("y".repeat(200)).length <= 80);
});

// ---------------------------------------------------------------- policy gates

test("policy: clearly non-actionable is auto noise", () => {
  const r = applyPolicy(answers({ actionable: NOISE_THRESHOLD - 0.01 }), 0.8);
  assert.deepEqual(r, { verdict: "noise", auto: true });
});

test("policy: borderline-actionable band escalates instead of auto-noising", () => {
  // The 0.2–0.5 band was auto-noise under the old 0.5 gate; a false noise
  // verdict silently drops real feedback, so it must escalate now.
  for (const actionable of [NOISE_THRESHOLD, 0.3, 0.49]) {
    const r = applyPolicy(answers({ actionable }), 0.8);
    assert.equal(r.verdict, "escalate", `actionable=${actionable}`);
    assert.equal(r.auto, false);
  }
});

test("policy: already_handled auto-accepts only with both gates satisfied", () => {
  const base = { actionable: 0.9, choice: "already_handled", confidence: 0.9, addressed: 0.85 };
  assert.deepEqual(applyPolicy(answers(base), 0.8), { verdict: "already_handled", auto: true });
  // addressed just under threshold (observed flapping band) must escalate
  assert.equal(applyPolicy(answers({ ...base, addressed: 0.79 }), 0.8).verdict, "escalate");
  assert.equal(applyPolicy(answers({ ...base, confidence: 0.79 }), 0.8).verdict, "escalate");
});

test("policy: fix/reject/defer always escalate", () => {
  for (const choice of ["fix", "reject", "defer"]) {
    const r = applyPolicy(answers({ actionable: 0.99, choice, confidence: 0.99 }), 0.8);
    assert.equal(r.verdict, "escalate");
    assert.equal(r.auto, false);
  }
});

// ---------------------------------------------------------------- thread -> point

test("toPoint skips resolved, empty, and PR-author-only threads", () => {
  assert.equal(toPoint(thread({ isResolved: true }), "author").skip, "resolved");
  assert.equal(toPoint(thread({ comments: { nodes: [] } }), "author").skip, "no comments");
  const ownOnly = thread({
    comments: { nodes: [{ author: { login: "author" }, body: "note to self", url: "u", createdAt: "t" }] },
  });
  assert.equal(toPoint(ownOnly, "author").skip, "PR-author thread only");
});

test("toPoint honors the reviewer filter", () => {
  assert.equal(toPoint(thread(), "author", ["someone-else"]).skip, "not from requested reviewers");
  assert.equal(toPoint(thread(), "author", ["reviewer"]).skip, undefined);
});

test("toPoint judges the thread's current ask (latest reviewer message wins)", () => {
  const withdrawn = thread({
    comments: {
      nodes: [
        { author: { login: "reviewer" }, body: "please extract a helper", url: "u1", createdAt: "t1" },
        { author: { login: "author" }, body: "ok?", url: "u2", createdAt: "t2" },
        { author: { login: "reviewer" }, body: "never mind, fine as is", url: "u3", createdAt: "t3" },
      ],
    },
  });
  const p = toPoint(withdrawn, "author");
  assert.equal(p.latestMessage, "never mind, fine as is");
  assert.equal(p.url, "u3");
});

test("latestReviewerMessage falls back to the last comment overall", () => {
  const comments = [
    { author: "reviewer", body: "b1" },
    { author: "author", body: "b2" },
  ];
  assert.equal(latestReviewerMessage(comments, "author").body, "b1");
  assert.equal(latestReviewerMessage([{ author: "author", body: "b1" }], "author").body, "b1");
});

// ---------------------------------------------------------------- diff hunks

const DIFF = `diff --git a/f.txt b/f.txt
index 0000000..1111111 100644
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,4 @@
 near context
+near addition
 more
@@ -200,3 +200,4 @@
 far context
+far addition
 more
diff --git a/g.txt b/g.txt
index 0000000..1111111 100644
--- a/g.txt
+++ b/g.txt
@@ -5,2 +5,3 @@
 other file
+x
`;

test("diffHunksNear keeps far hunks, ordered nearest-first", () => {
  const out = diffHunksNear(DIFF, "f.txt", 2);
  assert.ok(out.includes("near addition"), "near hunk present");
  assert.ok(out.includes("far addition"), "far hunk not dropped (coverage-fix blind spot)");
  assert.ok(out.indexOf("near addition") < out.indexOf("far addition"), "nearest first");
  assert.ok(!out.includes("other file"), "other files excluded");
});

test("diffHunksNear handles missing file and empty diff", () => {
  assert.equal(diffHunksNear(DIFF, "nope.txt", 2), "");
  assert.equal(diffHunksNear("", "f.txt", 2), "");
});

// ---------------------------------------------------------------- code excerpt (temp git repo)

function withTempRepo(fn) {
  const dir = mkdtempSync(path.join(tmpdir(), "triage-test-"));
  const prev = process.cwd();
  const git = (args) =>
    execFileSync("git", args, { cwd: dir, stdio: ["ignore", "pipe", "ignore"] });
  try {
    process.chdir(dir);
    git(["init", "-q"]);
    const committed = Array.from({ length: 100 }, (_, i) => `c${i + 1}`).join("\n") + "\n";
    writeFileSync(path.join(dir, "file.txt"), committed);
    git(["add", "file.txt"]);
    git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]);
    // Working tree drifts: same line count, different content.
    writeFileSync(
      path.join(dir, "file.txt"),
      Array.from({ length: 100 }, (_, i) => `w${i + 1}`).join("\n") + "\n",
    );
    writeFileSync(path.join(dir, "untracked.txt"), "only in working tree\n");
    fn(dir);
  } finally {
    process.chdir(prev);
    rmSync(dir, { recursive: true, force: true });
  }
}

test("codeExcerpt reads the PR head commit, not the drifted working tree", () => {
  withTempRepo(() => {
    const out = codeExcerpt("file.txt", 50, "HEAD");
    assert.ok(out.includes("50: c50"), "committed content wins (coordinate fix)");
    assert.ok(!out.includes("w50"), "no working-tree drift leaks in");
  });
});

test("codeExcerpt windows ±40 lines around the anchor", () => {
  withTempRepo(() => {
    const lines = codeExcerpt("file.txt", 50, "HEAD").split("\n");
    assert.equal(lines[0], `10: c10`);
    assert.equal(lines.at(-1), `90: c90`);
    assert.equal(lines.length, 81);
  });
});

test("codeExcerpt: file absent at the commit yields null even if in the working tree", () => {
  withTempRepo(() => {
    assert.equal(codeExcerpt("untracked.txt", 1, "HEAD"), null);
    assert.ok(codeExcerpt("untracked.txt", 1, null).includes("only in working tree"));
  });
});

test("codeExcerpt: unfetched commit falls back to the working tree", () => {
  withTempRepo(() => {
    const out = codeExcerpt("file.txt", 50, "0".repeat(40));
    assert.ok(out.includes("50: w50"), "working-tree fallback for unfetched commit");
  });
});

// ---------------------------------------------------------------- state + render

test("buildState carries clipped commit messages and honest placeholders", () => {
  const pr = { title: "t", body: "b", url: "u", commits: "C".repeat(CAPS.commits + 500) };
  const point = { path: "x", line: 1, isOutdated: false, comments: [{ author: "r", body: "b" }] };
  const state = buildState(pr, point, null, "");
  assert.ok(state.pr.commits.length <= CAPS.commits + 20, "commits clipped");
  assert.match(state.current_code, /no excerpt: file not found at the PR head commit/);
  assert.equal(state.diff_hunks, "(no diff available for this file)");
});

test("renderMarkdown groups verdicts and keeps suggestion detail for escalations", () => {
  const mk = (verdict, auto, extra = {}) => ({
    point: { path: "a.ts", line: 1, latestMessage: "msg", url: "u" },
    answers: answers(extra),
    verdict,
    auto,
  });
  const out = renderMarkdown(
    [mk("already_handled", true, { choice: "already_handled" }), mk("noise", true, { actionable: 0.05 }), mk("escalate", false)],
    0.8,
  );
  assert.match(out, /3 threads → 1 already handled · 1 noise · 1 escalated/);
  assert.match(out, /jev suggests \*\*fix\*\*/);
});
