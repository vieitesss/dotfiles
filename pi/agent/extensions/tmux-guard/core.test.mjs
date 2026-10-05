// Hermetic tests for the Pi tmux guard adapter.  No network: runCore is always
// stubbed, so no API key is ever needed.  Run: node --test <this file>

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createToolCallHandler, evaluate, findGuard, needsGuard, parseDecision } from "./core.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", "..", "..");
const GUARD = join(REPO, "scripts", "tmux-guard");
const reply = (stdout, code = 0) => async () => ({ code, stdout: code ? "" : stdout, stderr: "" });
const call = (handler, ctx, command = "tmux kill-server") =>
	handler({ toolName: "bash", input: { command } }, ctx);
const ui = (confirm) => ({ cwd: "/w", hasUI: true, ui: { confirm } });
const blockReason = (result) => {
	assert.equal(result.block, true);
	return result.reason;
};

test("prefilter and protocol", () => {
	for (const command of ["tmux kill-server", "/opt/homebrew/bin/tmux ls", "pkill -f tmux", "echo tmux"]) {
		assert.equal(needsGuard(command), true, command);
	}
	for (const command of ["ls -la", "pkill -f node", "git status", ""]) {
		assert.equal(needsGuard(command), false, command);
	}
	assert.deepEqual(parseDecision("allow\n"), { kind: "allow" });
	assert.deepEqual(parseDecision("ask\trisk 0.80\n"), { kind: "ask", reason: "risk 0.80" });
	for (const text of ["maybe", "allow extra", ""]) assert.equal(parseDecision(text), null, text);
});

test("findGuard resolves the checkout through symlinks, then the installed path", () => {
	const env = { ...process.env, HOME: undefined };
	assert.equal(findGuard({ importMetaUrl: pathToFileURL(join(HERE, "core.mjs")).href, env }), GUARD);
	const tmp = mkdtempSync(join(tmpdir(), "pi-guard-test."));
	try {
		mkdirSync(join(tmp, "ext"));
		symlinkSync(HERE, join(tmp, "ext", "tmux-guard"));
		const url = pathToFileURL(join(tmp, "ext", "tmux-guard", "core.mjs")).href;
		assert.equal(findGuard({ importMetaUrl: url, env }), GUARD);
		mkdirSync(join(tmp, "home", ".local", "bin"), { recursive: true });
		const installed = join(tmp, "home", ".local", "bin", "tmux-guard");
		writeFileSync(installed, "#!/bin/sh\n");
		assert.equal(findGuard({ env: { ...env, HOME: join(tmp, "home") } }), installed);
		assert.equal(findGuard({ env: { ...env, HOME: join(tmp, "empty") } }), null);
	} finally {
		rmSync(tmp, { recursive: true, force: true });
	}

});

test("evaluate skips unrelated commands, maps decisions, and never allows on failure", async () => {
	let called = 0;
	const skip = { command: "ls -la", cwd: "/w", runCore: async () => { called += 1; } };
	assert.deepEqual(await evaluate(skip), { kind: "allow" });
	assert.equal(called, 0);
	const ask = { command: "tmux kill-server", cwd: "/w", runCore: reply("ask\trisk 0.80\n") };
	assert.deepEqual(await evaluate({ ...ask, runCore: reply("allow\n") }), { kind: "allow" });
	assert.deepEqual(await evaluate(ask), { kind: "ask", reason: "risk 0.80" });
	const failures = [
		reply("unreadable\n"),
		async () => ({ code: 2, stdout: "", stderr: "boom" }),
		async () => { throw new Error("spawn failed"); },
		async () => undefined,
	];
	for (const runCore of failures) {
		assert.equal((await evaluate({ command: "tmux kill-server", cwd: "/w", runCore })).kind, "deny");
	}
});

test("handler ignores other tools and empty commands", async () => {
	const handler = createToolCallHandler({
		runCore: async () => {
			throw new Error("should not run");
		},
	});
	assert.equal(await handler({ toolName: "read", input: { path: "x" } }, ui(async () => true)), undefined);
	assert.equal(await handler({ toolName: "bash", input: {} }, ui(async () => true)), undefined);
});

test("handler asks the human, blocks without a UI, and blocks guard failures", async () => {
	const ask = createToolCallHandler({ runCore: reply("ask\trisk 0.80\n") });
	assert.equal(await call(ask, ui(async () => true)), undefined);
	assert.equal(blockReason(await call(ask, ui(async () => false))), "Blocked by user");
	assert.match(blockReason(await call(ask, { cwd: "/w", hasUI: false })), /no UI available/);
	assert.match(
		blockReason(await call(ask, ui(async () => { throw new Error("dialog lost"); }))),
		/could not ask/,
	);

	let prompted = 0;
	const failing = createToolCallHandler({ runCore: reply("not found", 127) });
	const prompting = ui(async () => {
		prompted += 1;
		return true;
	});
	const nested = {
		toolName: "bash",
		toolCallId: "n1",
		parentToolCallId: "p1",
		input: { command: "tmux kill-server" },
	};
	assert.match(blockReason(await failing(nested, prompting)), /exit 127/);
	assert.equal(prompted, 0);
});
