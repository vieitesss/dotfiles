#!/usr/bin/env node
//
// guard.mjs — Jev (TypeSafe System One) pre-commit guardrail for the
// commit-changes skill.
//
// Shape (docs/issues/0002-jev-commit-changes-guardrails.md): check a drafted
// one-line Conventional Commit message against the staged diff, and screen
// the diff locally for likely secrets before any of it leaves the machine.
//   message_matches (Noul)    does the drafted message accurately describe the diff?
//   commit_type     (Choice)  advisory Conventional Commit type for the same diff
// Jev never writes or replaces the message; it only judges it.
//
// Security: the complete diff (added, removed, and context lines) and the
// message are screened locally before truncation and before any TypeSafe
// call. The screen is pattern based and best effort — it can block a group,
// but it cannot guarantee that every secret is found. Any pattern hit, or
// added content in a sensitive path, blocks the group and exits before the
// SDK is imported, so nothing is transmitted.
//
// Usage (from the repo whose changes are staged):
//   node guard.mjs --message "fix: correct the retry backoff"
//   node guard.mjs --message "docs: ..." --diff-file /tmp/group.diff --json
//
// Exit codes: 0 guard ran and printed a verdict · 2 could not read the diff
// · 3 no TYPESAFE_API_KEY, continue visibly unverified · 4 every Jev call
// failed, continue visibly unverified · 5 invalid argument
// · 6 blocked_secrets (no TypeSafe call made).

import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const EXIT = { diff: 2, noKey: 3, allFailed: 4, args: 5, blocked: 6 };

const HELP = `guard.mjs — Jev guardrail for a drafted commit message

Options:
  --message <text>          drafted one-line Conventional Commit message (required)
  --diff-file <path>        read the diff from a file instead of \`git diff --cached\`
  --stdin                   read the diff from stdin
  --threshold <float>       Noul probability for a clean "ok" (default: 0.70)
  --revise-threshold <float> Noul probability at or below which to revise (default: 0.30)
  --model <name>            System One model (default: SDK default, jev-latest)
  --json                    print machine-readable JSON instead of markdown
  --help                    show this help

A local best-effort secret screen runs over the complete diff and the message
before anything is sent to TypeSafe. If it finds a likely secret, the group is
blocked and no API call is made. The screen cannot guarantee that every
secret is found.

Exit codes: 0 guard ran and printed a verdict · 2 could not read the diff
· 3 no TYPESAFE_API_KEY, continue visibly unverified · 4 every Jev call failed,
continue visibly unverified · 5 invalid argument · 6 blocked_secrets.
`;

// ---------------------------------------------------------------- args

function parseArgs(argv) {
  const args = { threshold: 0.70, reviseThreshold: 0.30, json: false, stdin: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help") {
      args.help = true;
    } else if (a === "--message") {
      args.message = argv[++i];
    } else if (a === "--diff-file") {
      args.diffFile = argv[++i];
    } else if (a === "--stdin") {
      args.stdin = true;
    } else if (a === "--threshold") {
      args.threshold = Number(argv[++i]);
      if (!(args.threshold >= 0 && args.threshold <= 1)) {
        fail(`invalid --threshold: ${argv[i]}`, EXIT.args);
      }
    } else if (a === "--revise-threshold") {
      args.reviseThreshold = Number(argv[++i]);
      if (!(args.reviseThreshold >= 0 && args.reviseThreshold <= 1)) {
        fail(`invalid --revise-threshold: ${argv[i]}`, EXIT.args);
      }
    } else if (a === "--model") {
      args.model = argv[++i];
    } else if (a === "--json") {
      args.json = true;
    } else {
      fail(`unknown argument: ${a}`, EXIT.args);
    }
  }
  if (args.stdin && args.diffFile) fail("--stdin and --diff-file are mutually exclusive", EXIT.args);
  if (!args.help && !args.message) fail("--message is required (or --help)", EXIT.args);
  if (args.reviseThreshold >= args.threshold) {
    fail("--revise-threshold must be below --threshold", EXIT.args);
  }
  return args;
}

function fail(message, code) {
  process.stderr.write(`guard: ${message}\n`);
  process.exit(code);
}

// ---------------------------------------------------------------- diff input

function readDiff(args) {
  if (args.diffFile) {
    try {
      return readFileSync(args.diffFile, "utf8");
    } catch (err) {
      fail(`could not read --diff-file ${args.diffFile}: ${err.message}`, EXIT.diff);
    }
  }
  if (args.stdin) {
    try {
      return readFileSync(0, "utf8");
    } catch (err) {
      fail(`could not read stdin: ${err.message}`, EXIT.diff);
    }
  }
  try {
    return execFileSync("git", ["diff", "--cached"], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch (err) {
    fail(`could not run git diff --cached: ${err.message}`, EXIT.diff);
  }
}

// ---------------------------------------------------------------- secret gate

// Paths whose contents are treated as sensitive. Matching alone does not
// block: a diff that only removes a sensitive file is redacted and can
// still be verified. Added content in a sensitive path blocks the group.
function isSensitivePath(filePath) {
  const base = path.basename(filePath);
  return (
    /^\.env/i.test(base) ||
    /^id_rsa/i.test(base) ||
    /\.(pem|key)$/i.test(base) ||
    /credential|secret/i.test(filePath)
  );
}

// High-precision markers only. Best effort: this can block a group, but it
// cannot promise that every secret is found.
const SECRET_PATTERNS = [
  { kind: "private_key", source: "-----BEGIN [A-Z ]*PRIVATE KEY-----" },
  { kind: "aws_access_key", source: "\\bAKIA[0-9A-Z]{16}\\b" },
  { kind: "github_token", source: "\\bgh[po]_[A-Za-z0-9]{20,}\\b" },
  { kind: "slack_token", source: "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b" },
].map((p) => ({ ...p, test: new RegExp(p.source), redact: new RegExp(p.source, "g") }));

const MAX_FINDINGS = 20;

function pathFromGitHeader(line) {
  const m = line.match(/^diff --git "?a\/(.+?)"? "?b\/(.+?)"?$/);
  return m ? m[2] : null;
}

function cleanDiffPath(raw) {
  const trimmed = raw.trim().replace(/^"|"$/g, "");
  if (!trimmed || trimmed === "/dev/null") return null;
  return trimmed.replace(/^b\//, "");
}

// Screen the raw message and the complete diff (every line, including
// removed and context lines) before anything is clipped or sent. Returns
// the redacted message and diff for the caller to build state from; when
// `blocked` is true the caller must not transmit anything.
function screenSecrets(message, diff) {
  const findings = [];
  let findingsTotal = 0;
  let blocked = false;
  const add = (finding) => {
    findingsTotal++;
    if (findings.length < MAX_FINDINGS) findings.push(finding);
  };

  let redactedMessage = message;
  for (const p of SECRET_PATTERNS) {
    if (p.test.test(redactedMessage)) {
      add({ path: "(message)", line: null, kind: p.kind });
      blocked = true;
      redactedMessage = redactedMessage.replace(p.redact, "[REDACTED]");
    }
  }

  const out = [];
  let file = null;
  let sensitive = false;
  let sensitiveAdded = false;
  let sensitiveFirstAddedLine = null;
  let inHunk = false;
  let oldLine = null;
  let newLine = null;
  let files = 0;

  const finishFile = () => {
    if (file && sensitive && sensitiveAdded) {
      add({ path: file, line: sensitiveFirstAddedLine, kind: "sensitive_path_added" });
      blocked = true;
    }
    file = null;
    sensitive = false;
    sensitiveAdded = false;
    sensitiveFirstAddedLine = null;
    inHunk = false;
    oldLine = null;
    newLine = null;
  };

  const content = (prefix, raw, lineNo) => {
    if (sensitive) {
      out.push(`${prefix}[REDACTED]`);
      return;
    }
    let text = raw;
    for (const p of SECRET_PATTERNS) {
      if (p.test.test(text)) {
        add({ path: file, line: lineNo, kind: p.kind });
        blocked = true;
        text = text.replace(p.redact, "[REDACTED]");
      }
    }
    out.push(text);
  };

  for (const raw of diff.split("\n")) {
    if (raw.startsWith("diff --git ")) {
      finishFile();
      file = pathFromGitHeader(raw);
      sensitive = file ? isSensitivePath(file) : false;
      files++;
      out.push(raw);
      continue;
    }
    // `--- `/`+++ ` are file headers only before the first hunk; inside a
    // hunk they can be removed/added source lines that happen to start
    // with dashes or pluses.
    if (!inHunk && raw.startsWith("+++ ")) {
      const p = cleanDiffPath(raw.slice(4));
      if (p) {
        file = p;
        sensitive = isSensitivePath(file);
      }
      out.push(raw);
      continue;
    }
    if (!inHunk && raw.startsWith("--- ")) {
      const p = cleanDiffPath(raw.slice(4));
      if (p && !file) {
        file = p;
        sensitive = isSensitivePath(file);
      }
      out.push(raw);
      continue;
    }
    if (raw.startsWith("@@ ")) {
      const m = raw.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
      if (m) {
        oldLine = Number(m[1]);
        newLine = Number(m[2]);
      }
      inHunk = true;
      out.push(raw);
      continue;
    }
    if (raw.startsWith("+")) {
      const lineNo = newLine;
      newLine = newLine === null ? null : newLine + 1;
      if (sensitive) {
        sensitiveAdded = true;
        if (sensitiveFirstAddedLine === null) sensitiveFirstAddedLine = lineNo;
      }
      content("+", raw, lineNo);
      continue;
    }
    if (raw.startsWith("-")) {
      const lineNo = oldLine;
      oldLine = oldLine === null ? null : oldLine + 1;
      content("-", raw, lineNo);
      continue;
    }
    if (raw.startsWith(" ")) {
      const lineNo = newLine;
      oldLine = oldLine === null ? null : oldLine + 1;
      newLine = newLine === null ? null : newLine + 1;
      content(" ", raw, lineNo);
      continue;
    }
    out.push(raw);
  }
  finishFile();

  return {
    blocked,
    findings,
    findingsTotal,
    message: redactedMessage,
    diff: out.join("\n"),
    stats: { files, diffLines: diff.split("\n").length, messageChars: message.length },
  };
}

function renderBlocked(screen, json) {
  if (json) {
    return JSON.stringify(
      {
        verdict: "blocked_secrets",
        screen: "best-effort local pattern scan; not a guarantee that every secret is found",
        transport: "no TypeSafe call made",
        findingsTotal: screen.findingsTotal,
        findings: screen.findings,
        stats: screen.stats,
      },
      null,
      2,
    );
  }
  const lines = [
    "## Commit guard: BLOCKED — likely secret detected",
    "Best-effort local screen (pattern based; not a guarantee that every secret is found). No TypeSafe call was made.",
    "",
  ];
  for (const f of screen.findings) {
    lines.push(`- \`${f.path}${f.line === null ? "" : `:${f.line}`}\` — ${f.kind}`);
  }
  if (screen.findingsTotal > screen.findings.length) {
    lines.push(`- … and ${screen.findingsTotal - screen.findings.length} more`);
  }
  lines.push("", "Unstage or redact these changes, then rerun the guard. Do not commit this group as-is.");
  return lines.join("\n");
}

// ---------------------------------------------------------------- state & questions

// Character budget for the staged diff, applied after the local secret
// screen and before the TypeSafe call. This is a conservative character
// heuristic, not a token guarantee: no exact char-to-token mapping is
// documented. The live limits (https://docs.typesafe.ai/models.md) are 64k
// tokens per request, of which 32k tokens cover `state` plus the longest
// question. jev-1.13 also gets less accurate as `state` grows with content
// unrelated to the question. Ordinary staged diffs stay whole under this
// budget; diffs over it are clipped, flagged via `staged_diff_truncated`,
// and can never be auto-`ok`.
const DIFF_MAX_CHARS = 48000;

function clip(text, max) {
  return text.length <= max ? text : `${text.slice(0, max)}\n… [truncated]`;
}

function changedFiles(diff) {
  const files = [];
  for (const line of diff.split("\n")) {
    if (!line.startsWith("diff --git ")) continue;
    const p = pathFromGitHeader(line);
    if (p && !files.includes(p)) files.push(p);
  }
  return files;
}

// Named state Jev reads: the drafted message, the changed paths, and the
// redacted staged diff. Truncation is explicit in the state so neither Jev
// nor the policy can mistake a clipped diff for the whole change. `screen`
// carries the locally screened message/diff from screenSecrets().
function buildState(screen) {
  const truncated = screen.diff.length > DIFF_MAX_CHARS;
  const state = {
    message: screen.message,
    files: changedFiles(screen.diff),
    staged_diff: truncated ? clip(screen.diff, DIFF_MAX_CHARS) : screen.diff,
    staged_diff_truncated: truncated,
  };
  return { state, truncated };
}

// Both questions see the same state in one parallel request. Jev judges the
// drafted message; it never writes or replaces one.
const QUESTIONS = {
  message_matches: {
    type: "noul",
    instructions:
      "The state holds one commit's drafted one-line message in `message` and that commit's " +
      "staged changes in `staged_diff`, with the changed paths in `files`. Does `message` " +
      "accurately describe what `staged_diff` changes? Answer yes only when the message's " +
      "claim and scope match the diff: a message that names different work, omits the main " +
      "change, or overstates the change is not accurate. When `staged_diff_truncated` is " +
      "true, the diff shown is incomplete.",
    criteria: {
      true: "The message accurately describes the staged change and its scope.",
      false:
        "The message names different work, omits the main change, or overstates or contradicts the diff.",
    },
  },
  commit_type: {
    type: "choice",
    instructions:
      "Which Conventional Commit type best matches the staged changes in `staged_diff` " +
      "(changed paths in `files`)? Judge the diff itself; `message` is context only.",
    criteria: {
      feat: "Adds a user-visible capability.",
      fix: "Fixes a bug or defect.",
      docs: "Documentation only.",
      refactor: "Restructures code without changing behavior.",
      test: "Tests only.",
      chore: "Maintenance that is none of the above (tooling, dependencies, configuration).",
    },
  },
};

async function judge(args, state) {
  // Imported only after the local screen passes and a key exists, so the
  // blocked and unverified paths never load the SDK.
  const { TypeSafeClient } = await import("@typesafe-ai/sdk");
  // Default log level (warn) only. SDK `debug` logs request bodies, and the
  // body contains the diff; never raise it here.
  const client = new TypeSafeClient();
  const request = { state, questions: QUESTIONS };
  if (args.model) request.model = args.model;
  const response = await client.systemOne(request);
  return {
    model: response.model,
    answers: response.answers,
    usage: response.usage,
  };
}

// Exit 3/4 path: the guard did not run, and that must be visible.
function renderUnverified(reason, truncated, json) {
  if (json) {
    return JSON.stringify(
      { verdict: "unverified", reason, staged_diff_truncated: truncated },
      null,
      2,
    );
  }
  return [
    "## Commit guard: UNVERIFIED — Jev did not run",
    `${reason}. The message/diff pair was not verified and nothing was sent.`,
    "Handle this group under the skill's unverified path; the guard gives no verdict.",
  ].join("\n");
}

// ---------------------------------------------------------------- policy & render

// The policy lives in code, not in the model: Jev returns probabilities, and
// these thresholds turn them into one of three verdicts. A clipped diff can
// never be `ok`. commit_type is advisory only: it may suggest a prefix, but
// it never changes the verdict and never mutates the drafted message.
function applyPolicy(answers, { truncated, threshold, reviseThreshold }) {
  const match = answers.message_matches.noul;
  const type = answers.commit_type;
  const commit_type = {
    suggestion: type.choice,
    confidence: type.confidence,
    advisory: true,
    adopt_prefix: type.confidence >= 0.8,
  };

  // A clear mismatch is `revise` even when the diff was clipped: truncation
  // removes evidence, so a clipped diff can never be `ok`, but it does not
  // erase a low score. Every other clipped case falls to `uncertain`.
  if (match <= reviseThreshold) {
    return {
      verdict: "revise",
      reason:
        `message_matches is at or below the revise threshold (${reviseThreshold})` +
        (truncated ? " (the staged diff was clipped; the low score still calls for a rewrite)" : ""),
      message_matches: match,
      truncated,
      commit_type,
    };
  }
  if (truncated) {
    return {
      verdict: "uncertain",
      reason:
        "staged diff was truncated at " + DIFF_MAX_CHARS + " chars; the shown diff is incomplete, so the match cannot be verified as a whole",
      message_matches: match,
      truncated,
      commit_type,
    };
  }
  if (match >= threshold) {
    return { verdict: "ok", reason: null, message_matches: match, truncated, commit_type };
  }
  return {
    verdict: "uncertain",
    reason: `message_matches is between the revise (${reviseThreshold}) and ok (${threshold}) thresholds`,
    message_matches: match,
    truncated,
    commit_type,
  };
}

const VERDICT_HEADLINE = {
  ok: "OK — message matches the staged diff",
  revise: "REVISE — message does not match the staged diff",
  uncertain: "UNCERTAIN — message match needs a human look",
};

function renderGuardResult(policy, result, json) {
  if (json) {
    return JSON.stringify(
      {
        verdict: policy.verdict,
        reason: policy.reason,
        message_matches: policy.message_matches,
        staged_diff_truncated: policy.truncated,
        commit_type: policy.commit_type,
        model: result.model,
        usage: result.usage,
      },
      null,
      2,
    );
  }
  const lines = [
    `## Commit guard: ${VERDICT_HEADLINE[policy.verdict]}`,
    `message_matches ${policy.message_matches.toFixed(2)} · staged_diff_truncated ${policy.truncated}`,
  ];
  if (policy.reason) lines.push(`reason: ${policy.reason}`);
  const t = policy.commit_type;
  lines.push(
    `commit_type \`${t.suggestion}\` (confidence ${t.confidence.toFixed(2)}, advisory) — ` +
      (t.adopt_prefix
        ? "may adopt this prefix if the drafted message needs it"
        : "below 0.8, reference only: do not adopt the prefix"),
  );
  if (policy.verdict === "revise") {
    lines.push("Revise the drafted message (bounded retries) and rerun the guard.");
  } else if (policy.verdict === "uncertain") {
    lines.push(
      policy.truncated
        ? "The staged diff was clipped, so the evidence is incomplete: do not rewrite the message; stop and report this group."
        : "Verify the drafted message against the staged diff by hand before continuing.",
    );
  }
  lines.push(
    "The guard never writes the message and is not commit approval; an explicit user request and the git-write guard still apply.",
  );
  return lines.join("\n");
}

// ---------------------------------------------------------------- main

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(HELP);
    return;
  }

  const diff = readDiff(args);
  const screen = screenSecrets(args.message, diff);
  if (screen.blocked) {
    process.stdout.write(renderBlocked(screen, args.json) + "\n");
    process.exitCode = EXIT.blocked;
    return;
  }

  const { state, truncated } = buildState(screen);

  if (!process.env.TYPESAFE_API_KEY) {
    process.stdout.write(
      renderUnverified("TYPESAFE_API_KEY is not set", truncated, args.json) + "\n",
    );
    process.exitCode = EXIT.noKey;
    return;
  }

  let result;
  try {
    result = await judge(args, state);
  } catch (err) {
    process.stdout.write(
      renderUnverified(`the Jev call failed: ${err.message}`, truncated, args.json) + "\n",
    );
    process.exitCode = EXIT.allFailed;
    return;
  }

  const policy = applyPolicy(result.answers, {
    truncated,
    threshold: args.threshold,
    reviseThreshold: args.reviseThreshold,
  });
  process.stdout.write(renderGuardResult(policy, result, args.json) + "\n");
}

// argv[1] keeps the invoked path while import.meta.url is fully resolved;
// this script can be invoked through a symlinked skills directory, so
// resolve argv[1] before comparing.
const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : null;
const isMain = invokedPath !== null && import.meta.url === pathToFileURL(invokedPath).href;
if (isMain) {
  main().catch((err) => fail(err.message ?? String(err), EXIT.allFailed));
}

// Exported for manual checks; not part of the CLI surface.
export {
  EXIT,
  QUESTIONS,
  applyPolicy,
  buildState,
  changedFiles,
  cleanDiffPath,
  clip,
  isSensitivePath,
  judge,
  parseArgs,
  pathFromGitHeader,
  readDiff,
  renderBlocked,
  renderGuardResult,
  renderUnverified,
  screenSecrets,
  DIFF_MAX_CHARS,
};
