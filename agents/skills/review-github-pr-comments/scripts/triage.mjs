#!/usr/bin/env node
//
// triage.mjs — Jev (TypeSafe System One) triage for GitHub PR review threads.
//
// Tier 1 of docs/issues/0001-jev-pr-comment-triage.md: per inline review
// thread, ask Jev three questions in one parallel request —
//   actionable        (Noul)  is the thread's current ask a code change?
//   already_addressed (Noul)  does the current code already resolve it?
//   decision          (Choice) fix / reject / defer / already_handled
// — and apply a conservative auto-accept policy:
//   actionable < NOISE_THRESHOLD (0.2)                 -> "noise" (auto)
//   decision=already_handled, confidence >= threshold,
//     already_addressed >= threshold                   -> "already_handled" (auto)
//   anything else (incl. every fix/reject/defer and
//     borderline-actionable threads)                   -> "escalate"
// The noise gate deliberately has margin: a false "noise" auto-verdict
// silently drops real feedback, the worst failure mode this script has
// (see docs/triage-eval-2026-09-19.md).
// Escalated points are decided manually by the agent in skill step 5.
//
// Usage (run from the repository root of the PR's branch):
//   node triage.mjs [--pr <number|url>] [--reviewers login,login]
//                   [--threshold 0.8] [--model jev-latest] [--json]
//                   [--fixture threads.json]
//
// Exit codes: 0 ok · 2 gh/PR resolution failure · 3 no TYPESAFE_API_KEY
// (skill falls back to fully manual triage) · 4 every Jev call failed.

import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

// ---------------------------------------------------------------- args

const HELP = `triage.mjs — Jev triage for PR review threads

Options:
  --pr <number|url>     PR to triage (default: current branch's PR)
  --reviewers a,b       keep only threads with a comment by these logins
  --threshold <float>   auto-accept confidence threshold (default: 0.8)
  --model <name>        System One model (default: SDK default, jev-latest)
  --fixture <file>      read threads from JSON file instead of querying gh
  --json                print full machine-readable JSON instead of markdown
  --help                show this help
`;

function parseArgs(argv) {
  const args = { threshold: 0.8, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help") {
      process.stdout.write(HELP);
      process.exit(0);
    } else if (a === "--json") {
      args.json = true;
    } else if (a === "--pr") {
      args.pr = argv[++i];
    } else if (a === "--reviewers") {
      args.reviewers = argv[++i].split(",").map((s) => s.trim()).filter(Boolean);
    } else if (a === "--threshold") {
      args.threshold = Number(argv[++i]);
      if (!(args.threshold >= 0 && args.threshold <= 1)) fail(`invalid --threshold: ${args.threshold}`, 5);
    } else if (a === "--model") {
      args.model = argv[++i];
    } else if (a === "--fixture") {
      args.fixture = argv[++i];
    } else {
      fail(`unknown argument: ${a}`, 5);
    }
  }
  return args;
}

function fail(message, code) {
  process.stderr.write(`triage: ${message}\n`);
  process.exit(code);
}

// ---------------------------------------------------------------- gh

function gh(args) {
  return execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function prNumberFrom(value) {
  if (!value) return null;
  const urlMatch = String(value).match(/\/pull\/(\d+)/);
  if (urlMatch) return Number(urlMatch[1]);
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : null;
}

const THREADS_QUERY = `query($owner:String!, $repo:String!, $pr:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          originalLine
          comments(last:20) {
            nodes { author { login } body createdAt url }
          }
        }
      }
    }
  }
}`;

function fetchFromGitHub(prArg) {
  let pr;
  try {
    const viewArgs = ["pr", "view", "--json", "number,title,body,url,author,headRefName,headRefOid,baseRefName"];
    if (prArg) viewArgs.splice(2, 0, String(prArg));
    pr = JSON.parse(gh(viewArgs));
  } catch {
    fail("could not resolve a PR (not on a PR branch, or gh not authenticated)", 2);
  }

  const repoInfo = JSON.parse(gh(["repo", "view", "--json", "owner,name"]));
  const owner = repoInfo.owner.login;
  const repo = repoInfo.name;

  const out = JSON.parse(gh([
    "api", "graphql",
    "-F", `owner=${owner}`,
    "-F", `repo=${repo}`,
    "-F", `pr=${pr.number}`,
    "-f", `query=${THREADS_QUERY}`,
  ]));

  let diff = "";
  try {
    diff = gh(["pr", "diff", String(pr.number)]);
  } catch {
    process.stderr.write("triage: warning: could not fetch PR diff; continuing without it\n");
  }

  return {
    pr: {
      number: pr.number, title: pr.title, body: pr.body ?? "", url: pr.url,
      author: pr.author?.login ?? "", headRefOid: pr.headRefOid ?? null,
      commits: prCommitMessages(pr.baseRefName, pr.headRefOid),
    },
    threads: out.data.repository.pullRequest.reviewThreads.nodes,
    diff,
  };
}

// Commit subjects + bodies of the PR's commits. Bodies carry footers (e.g.
// "BREAKING CHANGE:") that verdicts about release notes / process
// requirements need — evidence that thread text + code excerpts cannot
// show. Best-effort: empty when the base branch or commit is not fetched.
function prCommitMessages(baseRefName, headRefOid) {
  if (!baseRefName || !headRefOid) return "";
  try {
    const base = execFileSync("git", ["merge-base", `origin/${baseRefName}`, headRefOid], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!base) return "";
    return clip(
      execFileSync("git", ["log", "--no-decorate", "--format=%s%n%b", `${base}..${headRefOid}`], {
        encoding: "utf8",
        maxBuffer: 4 * 1024 * 1024,
        stdio: ["ignore", "pipe", "ignore"],
      }),
      CAPS.commits,
    );
  } catch {
    return "";
  }
}

function loadFixture(file) {
  const data = JSON.parse(readFileSync(file, "utf8"));
  return {
    pr: data.pr ?? { number: 0, title: "fixture", body: "", url: "", author: "" },
    threads: data.threads,
    diff: data.diff ?? "",
  };
}

// ---------------------------------------------------------------- points

const CAPS = { prBody: 1500, comment: 800, commentsTotal: 6000, diffHunks: 3000, code: 4000, commits: 1500 };
const CODE_CONTEXT_LINES = 40;

// Auto-verdict "noise" requires actionable below this margin — a false
// negative here silently discards real reviewer feedback. Threads in the
// 0.2–0.5 band escalate instead of auto-closing.
const NOISE_THRESHOLD = 0.2;

function clip(text, max) {
  if (!text) return "";
  return text.length <= max ? text : `${text.slice(0, max)}\n… [truncated]`;
}

function latestReviewerMessage(comments, prAuthor) {
  const reviewerComments = comments.filter((c) => c.author !== prAuthor);
  return reviewerComments.at(-1) ?? comments.at(-1) ?? null;
}

function toPoint(thread, prAuthor, reviewers) {
  if (thread.isResolved) return { skip: "resolved" };
  const comments = (thread.comments?.nodes ?? []).map((c) => ({
    author: c.author?.login ?? "unknown",
    body: c.body ?? "",
    url: c.url ?? "",
    createdAt: c.createdAt ?? "",
  }));
  if (comments.length === 0) return { skip: "no comments" };
  if (reviewers && !comments.some((c) => reviewers.includes(c.author))) {
    return { skip: "not from requested reviewers" };
  }
  const latest = latestReviewerMessage(comments, prAuthor);
  if (!latest || (latest.author === prAuthor && comments.every((c) => c.author === prAuthor))) {
    return { skip: "PR-author thread only" };
  }
  const anchorLine = thread.line ?? thread.originalLine ?? null;
  return {
    path: thread.path ?? null,
    line: anchorLine,
    isOutdated: Boolean(thread.isOutdated),
    url: latest.url ?? comments.at(-1).url ?? "",
    latestMessage: latest.body,
    latestAuthor: latest.author,
    comments,
  };
}

// ---------------------------------------------------------------- evidence

function codeExcerpt(filePath, anchorLine, commitish) {
  if (!filePath) return null;
  let text = null;
  if (commitish) {
    // Thread line numbers and `gh pr diff` hunks are in PR-head-commit
    // coordinates, so excerpt the file at that commit; reading the working
    // tree instead misaligns the window whenever the local checkout has
    // drifted (uncommitted fixes, unpushed commits, stale branch).
    try {
      text = execFileSync("git", ["show", `${commitish}:${filePath}`], {
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
        stdio: ["ignore", "pipe", "ignore"],
      });
    } catch {
      // If the commit is available but the path lookup failed, the file does
      // not exist at the PR head (e.g. deleted by the PR) — nothing to
      // excerpt. Fall back to the working tree only when the commit itself
      // is not fetched locally.
      try {
        execFileSync("git", ["cat-file", "-e", commitish], { stdio: "ignore" });
        return null;
      } catch {
        /* commit not fetched — use the working tree below */
      }
    }
  }
  let lines;
  try {
    lines = (text ?? readFileSync(path.resolve(process.cwd(), filePath), "utf8")).split("\n");
  } catch {
    return null;
  }
  const anchor = anchorLine ?? 1;
  const start = Math.max(0, anchor - 1 - CODE_CONTEXT_LINES);
  const end = Math.min(lines.length, anchor + CODE_CONTEXT_LINES);
  const numbered = lines.slice(start, end).map((l, i) => `${start + i + 1}: ${l}`);
  return clip(numbered.join("\n"), CAPS.code);
}

// Line-based hunk splitter: a hunk runs from its "@@ " header to the next
// header (or end of section). A regex with a multiline `$` lookahead stops
// at the first line end and captures headers only — that bug kept all diff
// content out of Jev's evidence until the 2026-09-19 eval caught it.
function splitHunks(section) {
  const hunks = [];
  let current = null;
  for (const line of section.split("\n")) {
    if (line.startsWith("@@ ")) {
      if (current) hunks.push(current.join("\n"));
      current = [line];
    } else if (current) {
      current.push(line);
    }
  }
  if (current) hunks.push(current.join("\n"));
  return hunks;
}

// Order the file's hunks by distance to the anchor (near first), filling
// the budget with as much as fits. Fixes routinely land far from the
// commented line (e.g. added tests ~120 lines away), so dropping far hunks
// entirely made already-fixed threads unverifiable; ordering keeps the
// anchor's neighborhood first without hiding the rest.
function diffHunksNear(diff, filePath, anchorLine) {
  if (!diff || !filePath) return "";
  const sections = diff.split(/^diff --git /m).slice(1);
  const section = sections.find((s) => {
    const header = s.split("\n", 1)[0];
    return header.includes(`b/${filePath}`);
  });
  if (!section) return "";
  const hunks = splitHunks(section);
  if (hunks.length === 0) return clip(section, CAPS.diffHunks);
  const anchor = anchorLine ?? 0;
  const distance = (h) => {
    const m = h.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/);
    if (!m) return Number.MAX_SAFE_INTEGER;
    const start = Number(m[1]);
    const end = start + Number(m[2] ?? 1);
    if (start <= anchor && anchor <= end) return 0;
    return Math.min(Math.abs(start - anchor), Math.abs(end - anchor));
  };
  const ordered = [...hunks].sort((a, b) => distance(a) - distance(b));
  return clip(ordered.join("\n"), CAPS.diffHunks);
}

// ---------------------------------------------------------------- jev

const QUESTIONS = {
  actionable: {
    type: "noul",
    instructions:
      "The state describes a GitHub pull request review thread. Is the latest reviewer " +
      "message in `thread.comments` an actionable request about the code — something the " +
      "PR author should change, fix, or clarify in code — as opposed to praise, a general " +
      "summary, or an observation that asks for no change? Later comments in the thread may " +
      "narrow or withdraw the original request; judge the thread's current ask.",
    criteria: {
      true: "The thread currently asks the author to change, fix, or clarify something in the code.",
      false: "The thread is praise, a summary, a question with no requested change, or its request was withdrawn.",
    },
  },
  already_addressed: {
    type: "noul",
    instructions:
      "Does the current code in `current_code` already address the concern raised by the " +
      "latest reviewer message in `thread.comments`, given what this PR changed in " +
      "`diff_hunks` and the commit messages in `pr.commits`? Answer yes only if the " +
      "concern is already resolved in the code as it stands now.",
    criteria: {
      true: "The current code already resolves the concern; no further change is needed.",
      false: "The concern is not resolved in the current code.",
    },
  },
  decision: {
    type: "choice",
    instructions:
      "What should the PR author do about the latest reviewer message in `thread.comments`? " +
      "Use `current_code`, `diff_hunks`, and the PR's commit messages in `pr.commits` as the " +
      "source of truth, not the comment text alone. Later thread comments may narrow or " +
      "withdraw the original concern.",
    criteria: {
      fix: "The point describes a real bug, regression, correctness, security, or meaningful maintainability issue that belongs in this PR.",
      reject: "The point is wrong, stale, contradicted by the current code, purely stylistic without support from project conventions, or conflicts with the PR's goal.",
      defer: "The point is reasonable but belongs in follow-up work outside this PR's scope.",
      already_handled: "The current branch already resolves the concern.",
    },
  },
};

function buildState(pr, point, code, diffHunks) {
  return {
    pr: { title: pr.title, body: clip(pr.body, CAPS.prBody), url: pr.url, commits: clip(pr.commits ?? "", CAPS.commits) },
    thread: {
      path: point.path,
      line: point.line,
      is_outdated: point.isOutdated,
      comments: clip(
        point.comments.map((c) => `${c.author}: ${clip(c.body, CAPS.comment)}`).join("\n---\n"),
        CAPS.commentsTotal,
      ),
    },
    diff_hunks: diffHunks || "(no diff available for this file)",
    current_code: code ?? "(no excerpt: file not found at the PR head commit or in the local checkout)",
  };
}

async function judgePoint(client, model, pr, point, diff) {
  const code = codeExcerpt(point.path, point.line, pr.headRefOid);
  const hunks = diffHunksNear(diff, point.path, point.line);
  const state = buildState(pr, point, code, hunks);
  const request = { state, questions: QUESTIONS };
  if (model) request.model = model;
  const response = await client.systemOne(request);
  return { state, answers: response.answers };
}

// Conservative tier-1 policy: only "noise" and "already_handled" are ever
// auto-accepted; every fix/reject/defer suggestion goes to the agent.
function applyPolicy(answers, threshold) {
  const actionable = answers.actionable.noul;
  const addressed = answers.already_addressed.noul;
  const decision = answers.decision;
  if (actionable < NOISE_THRESHOLD) return { verdict: "noise", auto: true };
  if (
    decision.choice === "already_handled" &&
    decision.confidence >= threshold &&
    addressed >= threshold
  ) {
    return { verdict: "already_handled", auto: true };
  }
  return { verdict: "escalate", auto: false };
}

async function pool(items, size, fn) {
  const results = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(size, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return results;
}

// ---------------------------------------------------------------- render

function oneLine(text, max = 80) {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
}

function renderMarkdown(results, threshold) {
  const groups = { already_handled: [], noise: [], escalate: [] };
  for (const r of results) groups[r.verdict].push(r);
  const out = [];
  out.push(
    `## Jev triage: ${results.length} threads → ` +
      `${groups.already_handled.length} already handled · ${groups.noise.length} noise · ` +
      `${groups.escalate.length} escalated (threshold ${threshold})`,
  );
  out.push("");
  out.push("### Auto: already handled");
  for (const r of groups.already_handled) {
    out.push(
      `- \`${r.point.path}:${r.point.line ?? "?"}\` — ${oneLine(r.point.latestMessage)} ` +
        `(conf ${r.answers.decision.confidence.toFixed(2)}, addressed ${r.answers.already_addressed.noul.toFixed(2)}) ${r.point.url}`,
    );
  }
  if (groups.already_handled.length === 0) out.push("- (none)");
  out.push("");
  out.push("### Auto: noise (not actionable)");
  for (const r of groups.noise) {
    out.push(
      `- \`${r.point.path}:${r.point.line ?? "?"}\` — ${oneLine(r.point.latestMessage)} ` +
        `(actionable ${r.answers.actionable.noul.toFixed(2)}) ${r.point.url}`,
    );
  }
  if (groups.noise.length === 0) out.push("- (none)");
  out.push("");
  out.push("### Escalated — decide manually per skill step 5");
  for (const r of groups.escalate) {
    const d = r.answers.decision;
    const probs = Object.entries(d.probabilities)
      .map(([k, v]) => `${k} ${v.toFixed(2)}`)
      .join(" / ");
    out.push(`- \`${r.point.path}:${r.point.line ?? "?"}\` — ${oneLine(r.point.latestMessage)}`);
    out.push(
      `  jev suggests **${d.choice}** (conf ${d.confidence.toFixed(2)}; ${probs}; ` +
        `actionable ${r.answers.actionable.noul.toFixed(2)}, addressed ${r.answers.already_addressed.noul.toFixed(2)})` +
        (r.error ? `; note: ${r.error}` : "") +
        ` ${r.point.url}`,
    );
  }
  if (groups.escalate.length === 0) out.push("- (none)");
  return out.join("\n");
}

// ---------------------------------------------------------------- main

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!process.env.TYPESAFE_API_KEY) {
    fail("TYPESAFE_API_KEY is not set — fall back to fully manual triage (skill steps 4-5)", 3);
  }

  const source = args.fixture ? loadFixture(args.fixture) : fetchFromGitHub(prNumberFrom(args.pr) ?? args.pr);

  const skipped = [];
  const points = [];
  for (const thread of source.threads) {
    const point = toPoint(thread, source.pr.author, args.reviewers);
    if (point.skip) skipped.push(point.skip);
    else if (!point.path) skipped.push("thread without a file path");
    else points.push(point);
  }
  if (skipped.length > 0) {
    const counts = skipped.reduce((m, s) => ((m[s] = (m[s] ?? 0) + 1), m), {});
    process.stderr.write(
      `triage: skipped threads: ${Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(", ")}\n`,
    );
  }
  if (points.length === 0) {
    process.stdout.write("## Jev triage: 0 threads to triage\n");
    return;
  }

  const { TypeSafeClient } = await import("@typesafe-ai/sdk");
  const client = new TypeSafeClient();

  let failures = 0;
  const results = await pool(points, 6, async (point) => {
    try {
      const { state, answers } = await judgePoint(client, args.model, source.pr, point, source.diff);
      return { point, state, answers, ...applyPolicy(answers, args.threshold) };
    } catch (err) {
      failures++;
      return {
        point,
        state: null,
        answers: {
          actionable: { noul: 1 },
          already_addressed: { noul: 0 },
          decision: { choice: "fix", confidence: 0, probabilities: {} },
        },
        verdict: "escalate",
        auto: false,
        error: `Jev call failed: ${err.message}`,
      };
    }
  });

  if (failures === points.length) {
    fail("every Jev call failed — fall back to fully manual triage (skill steps 4-5)", 4);
  }

  if (args.json) {
    process.stdout.write(JSON.stringify({ pr: source.pr, threshold: args.threshold, results }, null, 2));
  } else {
    process.stdout.write(renderMarkdown(results, args.threshold) + "\n");
  }
}

// argv[1] keeps the invoked path while import.meta.url is fully resolved;
// this script is usually invoked through a symlinked skills directory, so
// resolve argv[1] before comparing.
const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : null;
const isMain = invokedPath !== null && import.meta.url === pathToFileURL(invokedPath).href;
if (isMain) {
  main().catch((err) => fail(err.message ?? String(err), 4));
}

// Exported for tests (scripts/triage.test.mjs); not part of the CLI surface.
export {
  applyPolicy,
  buildState,
  clip,
  codeExcerpt,
  diffHunksNear,
  latestReviewerMessage,
  oneLine,
  prCommitMessages,
  prNumberFrom,
  renderMarkdown,
  toPoint,
  CAPS,
  CODE_CONTEXT_LINES,
  NOISE_THRESHOLD,
};
