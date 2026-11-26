// Test for pi/agent/extensions/program-resume.ts. Run: node --test tests/program-resume.test.mjs
//
// Covers the part that touches no terminal: the report it writes to stdout,
// the command it reopens pi with, the token it keeps across reloads, when it
// reports, and the Rex rule it has to agree with. Both report vectors are the
// ones the protocol spec (rev 0.5) spells out with the token below.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
	mac,
	makeReporter,
	report,
	resumeCommand,
	takeToken,
} from "../pi/agent/extensions/program-resume.ts";

const token = "dummy-token-replace-me";
const sessionFile = "/home/user/.pi/agent/sessions/session.jsonl";

/** The argv a report asks Rex to reopen, decoded out of the report itself. */
function reportedArgv(osc) {
	const body = osc.slice("\x1b]7577;".length, -"\x1b\\".length);
	const field = body.split(":").find((entry) => entry.startsWith("argv="));
	return field
		.slice("argv=".length)
		.split(",")
		.map((element) => Buffer.from(element, "base64").toString("utf8"));
}

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

test("reopens pi on the session file, with no flag at all", () => {
	assert.deepEqual(resumeCommand(sessionFile), ["pi", "--session", sessionFile]);
});

test("reports pi --session <file> whatever process.argv holds", () => {
	const written = [];
	const saved = process.argv;
	const reporter = makeReporter({
		token,
		pid: 74877,
		now: () => 1795543200000,
		exists: () => true,
		write: (text) => written.push(text),
	});
	try {
		// The regression: a flag reported here can never match the flags Rex
		// reads back from the OS, because pi sets process.title.
		process.argv = ["node", "/usr/local/bin/pi", "--model", "anthropic/opus", "--verbose"];
		reporter(sessionFile);
		process.argv = ["node", "/usr/local/bin/pi", "-e", "/extensions/one.ts", "--no-tools"];
		reporter("/sessions/second.jsonl");
	} finally {
		process.argv = saved;
	}

	assert.deepEqual(written.map(reportedArgv), [
		["pi", "--session", sessionFile],
		["pi", "--session", "/sessions/second.jsonl"],
	]);
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
		report({ pid: 74877, time: 1795543200, token, argv: ["pi", "--session", sessionFile] }),
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
	assert.match(written[1], /argv=cGk=,LS1zZXNzaW9u,L3Nlc3Npb25zL3NlY29uZC5qc29ubA==:mac=/);
});

test("the Rex rule trusts the session file and lists no flags", () => {
	const source = readFileSync(new URL("../rex/init.lua", import.meta.url), "utf8");
	const start = source.indexOf('rex.set("resume.trust.pi"');
	assert.notEqual(start, -1, "rex/init.lua has the resume.trust.pi rule");
	const block = source.slice(start, source.indexOf("\n})\n", start));

	assert.match(
		block,
		/command = \{ "pi", "--session", rex\.match\.under\(os\.getenv\("HOME"\) \.\. "\/\.pi\/agent\/sessions"\) \}/,
	);
	assert.equal(
		/\["--[^"]*"\]|\["-[^"]"\]/.test(block),
		false,
		"the rule lists no flags: pi's process.title makes every reported flag differ",
	);
});
