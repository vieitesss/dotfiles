// Test for pi/agent/extensions/program-resume.ts. Run: node --test tests/program-resume.test.mjs
//
// Covers the part that touches no terminal: the report it writes to stdout and
// the argument list it reopens pi with. Both report vectors are the ones the
// protocol spec (rev 0.5) spells out with the token below.

import assert from "node:assert/strict";
import test from "node:test";

import { mac, report, resumeArgv } from "../pi/agent/extensions/program-resume.ts";

const token = "dummy-token-replace-me";

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
			"/home/user/.pi/agent/sessions/session.jsonl",
		),
		["pi", "--model", "anthropic/opus", "-t", "read,grep", "--session", "/home/user/.pi/agent/sessions/session.jsonl"],
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
			"--skill",
			"/skills/one",
			"--offline",
			"-e",
			"/extensions/one.ts",
			"-e",
			"/extensions/two.ts",
			"--session",
			"/sessions/new.jsonl",
		],
	);
});
