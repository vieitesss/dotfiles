#!/usr/bin/env node
// Recover the final assistant text and turn outcome from a pi session file.
//
// usage: session-final.js <session.jsonl> <out.partial.md>
//
// stdout: 0 (ok) | 1 (error/aborted).
//   - 0 when the last assistant message has an end-turn stop reason, or when
//     the file contains no parseable JSON at all (foreign/fake session format).
//   - 1 when parseable session JSON exists but no assistant message was found.
//   - 1 when the last assistant message's stopReason is error or aborted.
// Writes the joined text content of the last assistant message into
// <out.partial.md> (overwrites; may be empty).
'use strict';
const fs = require("node:fs");
const [,, file, out] = process.argv;

let last;
let jsonSeen = false;
try {
  const text = fs.readFileSync(file, "utf8");
  for (const line of text.split("\n")) {
    if (!line) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof entry !== "object" || entry === null) continue;
    jsonSeen = true;
    if (entry.type === "message" && entry.message && entry.message.role === "assistant") {
      last = entry.message;
    }
  }
} catch {
  // Unreadable session: fall through to defaults.
}

let body = "";
if (last) {
  const parts = (last.content || [])
    .filter((c) => c && c.type === "text")
    .map((c) => c.text ?? "");
  body = parts.join("\n");
}
if (out) {
  try {
    fs.writeFileSync(out, body);
  } catch {
    // Artifact write failure must not mask the exit code.
  }
}
if (!last) {
  process.stdout.write(jsonSeen ? "1" : "0");
  process.exit(0);
}
const failed = last.stopReason === "error" || last.stopReason === "aborted";
process.stdout.write(failed ? "1" : "0");
