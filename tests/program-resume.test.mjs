// Test for pi/agent/extensions/program-resume.ts. Run: node --test tests/program-resume.test.mjs
//
// Covers the part that touches no terminal: the report it writes to stdout,
// the argument list it reopens pi with, the token it keeps across reloads,
// when it reports, and the Rex rule it has to agree with. Both report vectors
// are the ones the protocol spec (rev 0.5) spells out with the token below.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
	droppedFlags,
	keptFlags,
	mac,
	makeReporter,
	report,
	resumeArgv,
	takeToken,
} from "../pi/agent/extensions/program-resume.ts";

const token = "dummy-token-replace-me";
const sessionFile = "/home/user/.pi/agent/sessions/session.jsonl";

test("reports the Neovim example of the spec byte for byte", () => {
	assert.equal(
		report({
			pid: 74877,
			time: 1795543200,
			token,
			argv: ["nvim", "-S", "/home/user/.local/state/nvim/sessions/8f2c1d.vim"],
		}),
		"\x1b]7577;pid=74877:time=1795543200:argv=bnZpbQ==,LVM=,L2hvbWUvdXNlci8ubG9jYWwvc3RhdGUvbnZpbS9zZXNzaW9ucy84ZjJjMWQudmlt:mac=9dbb99bfb856749a87563839d7ce9062818d78cf25909db93f309e0cd3b1909b\x1b\\",
	);
});

test("signs the clear example of the spec", () => {
	assert.equal(
		mac("pid=74877:time=1795543200:clear=1", token),
		"c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93",
	);
});

test("reopens on the session file, keeping only the flags that shape the run", () => {
	assert.deepEqual(
		resumeArgv(
			["--model", "anthropic/opus", "-c", "--session", "/old.jsonl", "-t", "read,grep", "--plan", "--", "fix the bug"],
			sessionFile,
		),
		["pi", "--session", sessionFile, "--model", "anthropic/opus", "-t", "read,grep"],
	);
});

test("keeps the other run-shaping flags, and never a secret or the output mode", () => {
	assert.deepEqual(
		resumeArgv(
			[
				"--api-key",
				"sk-secret",
				"--skill",
				"/skills/one",
				"--offline",
				"-e",
				"/extensions/one.ts",
				"-e",
				"/extensions/two.ts",
				"--session",
				"/old.jsonl",
				"--mode",
				"json",
			],
			"/sessions/new.jsonl",
		),
		[
			"pi",
			"--session",
			"/sessions/new.jsonl",
			"--skill",
			"/skills/one",
			"--offline",
			"-e",
			"/extensions/one.ts",
			"-e",
			"/extensions/two.ts",
		],
	);
});

test("drops every session-picking and naming flag, and the values they take", () => {
	for (const argv of [
		["-c"],
		["--continue"],
		["-r"],
		["--resume"],
		["--session", "/old.jsonl"],
		["--session-id", "0190a1b2"],
		["--fork", "/forked.jsonl"],
		["-n", "a name"],
		["--name", "a name"],
	]) {
		assert.deepEqual(resumeArgv([...argv, "--verbose"], sessionFile), ["pi", "--session", sessionFile, "--verbose"], argv.join(" "));
	}
});

test("never keeps a value on a flag that takes none", () => {
	assert.deepEqual(
		resumeArgv(["--offline=1", "--verbose=1", "--model=anthropic/opus"], sessionFile),
		["pi", "--session", sessionFile, "--model=anthropic/opus"],
	);
});

test("keeps --verbose, which takes no value", () => {
	assert.equal(keptFlags.get("--verbose"), 0);
	assert.deepEqual(resumeArgv(["--verbose"], sessionFile), ["pi", "--session", sessionFile, "--verbose"]);
});

test("reports the token once per process, and takes it out of the environment", () => {
	const env = { OSC7577_TOKEN: token };
	const store = {};
	assert.equal(takeToken(env, store), token);
	assert.equal("OSC7577_TOKEN" in env, false);
	// /new, /resume, /fork and /reload load the extension again: the token
	// is no longer in the environment, so it has to come from the store.
	assert.equal(takeToken(env, store), token);
});

test("reports nothing without a token", () => {
	const env = {};
	assert.equal(takeToken(env, {}), undefined);
	assert.equal(takeToken({ OSC7577_TOKEN: "" }, {}), undefined);
});

test("waits for the session file, and reports each one once", () => {
	const written = [];
	const onDisk = new Set();
	const files = [];
	const reporter = makeReporter({
		token,
		argv: ["--model", "anthropic/opus"],
		pid: 74877,
		now: () => 1795543200000,
		exists: (path) => onDisk.has(path),
		write: (text) => written.push(text),
	});

	// A new session has a path but no file until its first message.
	reporter(sessionFile);
	assert.deepEqual(written, []);

	// A later event, after the file exists, reports it.
	onDisk.add(sessionFile);
	reporter(sessionFile);
	assert.deepEqual(written, [
		report({ pid: 74877, time: 1795543200, token, argv: ["pi", "--session", sessionFile, "--model", "anthropic/opus"] }),
	]);

	reporter(sessionFile);
	assert.equal(written.length, 1);

	// /new, /resume and /fork switch the file, and report only once it is there.
	files.push("/sessions/second.jsonl");
	reporter(files[0]);
	assert.equal(written.length, 1);
	onDisk.add(files[0]);
	reporter(files[0]);
	assert.equal(written.length, 2);
	assert.match(written[1], /argv=cGk=,LS1zZXNzaW9u,L3Nlc3Npb25zL3NlY29uZC5qc29ubA==,/);
});

test("the Rex rule lists the same flags, with the same values, as the reporter", () => {
	const source = readFileSync(new URL("../rex/init.lua", import.meta.url), "utf8");
	const start = source.indexOf('rex.set("resume.trust.pi"');
	assert.notEqual(start, -1, "rex/init.lua has the resume.trust.pi rule");
	const block = source.slice(start, source.indexOf("\n})\n", start));

	const rule = new Map();
	const entry = /\["([^"]+)"\]\s*=\s*(?:"(keep|drop)"|\{\s*"(keep|drop)",\s*values\s*=\s*(\d+)\s*\})/g;
	for (const [, name, bareKind, kind, values] of block.matchAll(entry)) {
		rule.set(name, { kind: bareKind ?? kind, values: values === undefined ? 0 : Number(values) });
	}

	const reported = new Map();
	for (const [name, values] of keptFlags) reported.set(name, { kind: "keep", values });
	for (const [name, values] of droppedFlags) reported.set(name, { kind: "drop", values });
	assert.deepEqual(Object.fromEntries(rule), Object.fromEntries(reported));
});
