// Hermetic tests for the Pi tmux guard adapter: pure mapping, mocked
// registration, and the real Python core over the CLI contract.
//
//   node --test pi/agent/extensions/tmux-guard/core.test.mjs

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

import {
	createToolCallHandler,
	evaluate,
	findGuard,
	needsGuard,
	parseDecision,
	registerTmuxGuard,
} from "./core.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", "..", "..");
const GUARD = join(REPO, "scripts", "tmux-guard");
const SANDBOX = join(REPO, "scripts", "tmux-sandbox");
const run = promisify(execFile);

const ALLOW = { kind: "allow" };
const denyReason = (result) => {
	assert.equal(result.block, true);
	return result.reason;
};

test("prefilter matches only commands the core could act on", () => {
	for (const command of [
		"tmux kill-server",
		"TMUX_TMPDIR=/tmp tmux ls",
		"pkill -f tmux",
		"killall tmux",
	]) {
		assert.equal(needsGuard(command), true, command);
	}
	for (const command of ["ls -la", "echo hello", "git status", ""]) {
		assert.equal(needsGuard(command), false, command);
	}
});

test("parseDecision understands the one-line protocol", () => {
	assert.deepEqual(parseDecision("allow\n"), ALLOW);
	assert.deepEqual(parseDecision("ask\tdo not do that"), {
		kind: "ask",
		reason: "do not do that",
	});
	assert.equal(parseDecision("maybe"), null);
	assert.equal(parseDecision("allow extra"), null);
	assert.equal(parseDecision(""), null);
});

test("findGuard resolves the checkout, symlinks, overrides, and the installed path", () => {
	const expected = GUARD;
	const env = { ...process.env };
	delete env.DOTFILES_TMUX_GUARD;
	delete env.HOME;

	assert.equal(findGuard({ importMetaUrl: pathToFileURL(join(HERE, "core.mjs")).href, env }), expected);

	const tmp = mkdtempSync(join(tmpdir(), "pi-guard-test."));
	try {
		const linked = join(tmp, "ext", "tmux-guard");
		mkdirSync(join(tmp, "ext"));
		symlinkSync(HERE, linked);
		const throughSymlink = pathToFileURL(join(linked, "core.mjs")).href;
		assert.equal(findGuard({ importMetaUrl: throughSymlink, env }), expected);

		const override = join(tmp, "my-guard");
		writeFileSync(override, "#!/bin/sh\n");
		assert.equal(
			findGuard({ env: { ...env, DOTFILES_TMUX_GUARD: override } }),
			override,
		);
		assert.equal(findGuard({ env: { ...env, HOME: tmp } }), null);
	} finally {
		rmSync(tmp, { recursive: true, force: true });
	}
});

test("evaluate skips the core for prefilter-negative commands", async () => {
	let called = 0;
	const result = await evaluate({
		command: "ls -la",
		cwd: "/work",
		runCore: async () => {
			called += 1;
			return { code: 0, stdout: "allow\n", stderr: "" };
		},
	});
	assert.deepEqual(result, ALLOW);
	assert.equal(called, 0);
});

test("evaluate maps core output", async () => {
	const ask = await evaluate({
		command: "tmux kill-server",
		cwd: "/work",
		runCore: async () => ({ code: 0, stdout: "ask\tlive socket\n", stderr: "" }),
	});
	assert.equal(ask.kind, "ask");
	assert.equal(ask.reason, "live socket");

	const allow = await evaluate({
		command: "tmux ls",
		cwd: "/work",
		runCore: async () => ({ code: 0, stdout: "allow\n", stderr: "" }),
	});
	assert.deepEqual(allow, ALLOW);
});

test("evaluate fails closed when the core fails", async () => {
	const errors = await evaluate({
		command: "tmux kill-server",
		cwd: "/work",
		runCore: async () => {
			throw new Error("spawn ENOENT");
		},
	});
	assert.equal(errors.kind, "deny");
	assert.match(errors.reason, /could not run/);

	const nonzero = await evaluate({
		command: "tmux kill-server",
		cwd: "/work",
		runCore: async () => ({ code: 2, stdout: "", stderr: "internal error" }),
	});
	assert.equal(nonzero.kind, "deny");
	assert.match(nonzero.reason, /internal error/);

	const garbage = await evaluate({
		command: "tmux kill-server",
		cwd: "/work",
		runCore: async () => ({ code: 0, stdout: "surprise\n", stderr: "" }),
	});
	assert.equal(garbage.kind, "deny");
});

test("handler ignores other tools and empty commands", async () => {
	const handler = createToolCallHandler({
		runCore: async () => {
			throw new Error("should not run");
		},
	});
	const ctx = { hasUI: true, ui: { confirm: async () => true } };
	assert.equal(await handler({ toolName: "read", input: { path: "x" } }, ctx), undefined);
	assert.equal(await handler({ toolName: "bash", input: {} }, ctx), undefined);
});

test("handler approves, denies, and blocks without UI", async () => {
	const askCore = async () => ({ code: 0, stdout: "ask\tlive socket\n", stderr: "" });
	const handler = createToolCallHandler({ runCore: askCore });

	const approved = await handler(
		{ toolName: "bash", input: { command: "tmux kill-server" } },
		{ cwd: "/work", hasUI: true, ui: { confirm: async () => true } },
	);
	assert.equal(approved, undefined);

	const denied = await handler(
		{ toolName: "bash", input: { command: "tmux kill-server" } },
		{ cwd: "/work", hasUI: true, ui: { confirm: async () => false } },
	);
	assert.equal(denyReason(denied), "Blocked by user");

	const headless = await handler(
		{ toolName: "bash", input: { command: "tmux kill-server" } },
		{ cwd: "/work", hasUI: false },
	);
	assert.match(denyReason(headless), /no UI available/);

	const throwing = await handler(
		{ toolName: "bash", input: { command: "tmux kill-server" } },
		{
			cwd: "/work",
			hasUI: true,
			ui: {
				confirm: async () => {
					throw new Error("dialog lost");
				},
			},
		},
	);
	assert.match(denyReason(throwing), /could not ask/);
});

test("handler blocks core failures without prompting", async () => {
	let prompted = 0;
	const handler = createToolCallHandler({
		runCore: async () => ({ code: 127, stdout: "", stderr: "not found" }),
	});
	const blocked = await handler(
		{ toolName: "bash", input: { command: "tmux kill-server" } },
		{
			cwd: "/work",
			hasUI: true,
			ui: {
				confirm: async () => {
					prompted += 1;
					return true;
				},
			},
		},
	);
	assert.match(denyReason(blocked), /exit 127/);
	assert.equal(prompted, 0);
});

test("mocked registration wires tool_call to the core", async () => {
	const handlers = new Map();
	const fakePi = {
		on(event, handler) {
			handlers.set(event, handler);
			return () => {};
		},
	};
	registerTmuxGuard(fakePi, {
		runCore: async (command) => ({
			code: 0,
			stdout: command.includes("kill") ? "ask\tlive socket\n" : "allow\n",
			stderr: "",
		}),
	});
	assert.equal(typeof handlers.get("tool_call"), "function");

	const ctx = { cwd: "/work", hasUI: true, ui: { confirm: async () => false } };
	const blocked = await handlers.get("tool_call")(
		{ toolName: "bash", input: { command: "tmux kill-server" } },
		ctx,
	);
	assert.equal(denyReason(blocked), "Blocked by user");
	const allowed = await handlers.get("tool_call")(
		{ toolName: "bash", input: { command: "tmux ls" } },
		ctx,
	);
	assert.equal(allowed, undefined);
});

test("real core: allow, ask, and owned-socket allow", async () => {
	const env = { ...process.env };
	delete env.TMUX;
	delete env.TMUX_PANE;

	const core = async (command) => {
		try {
			const { stdout } = await run(GUARD, ["--", command], { env, timeout: 10000 });
			return { code: 0, stdout, stderr: "" };
		} catch (error) {
			return { code: error.code ?? 1, stdout: error.stdout ?? "", stderr: error.stderr ?? "" };
		}
	};

	const allowed = await evaluate({ command: "tmux ls", cwd: REPO, runCore: core });
	assert.deepEqual(allowed, ALLOW);

	const asked = await evaluate({
		command: "tmux kill-server",
		cwd: REPO,
		runCore: core,
	});
	assert.equal(asked.kind, "ask");

	const state = (
		await run(SANDBOX, ["new"], { env, timeout: 10000 })
	).stdout.trim();
	assert.ok(existsSync(state), "sandbox state was not created");
	try {
		const socket = join(state, "run", "tmux.sock");
		const owned = await evaluate({
			command: `tmux -S ${socket} kill-server`,
			cwd: REPO,
			runCore: core,
		});
		assert.deepEqual(owned, ALLOW);
	} finally {
		await run(SANDBOX, ["cleanup", "--state", state], { env, timeout: 10000 });
		rmSync(state, { recursive: true, force: true });
	}
});

test("real core: missing executable denies", async () => {
	const result = await evaluate({
		command: "tmux kill-server",
		cwd: REPO,
		runCore: async () => {
			throw new Error("spawn /nonexistent ENOENT");
		},
	});
	assert.equal(result.kind, "deny");
});
