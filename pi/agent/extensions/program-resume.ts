/**
 * Reports this pi process to the Program Resume protocol (OSC 7577), so a Rex
 * server restart opens pi again on the session file it has open. Rex accepts
 * the report through the resume.trust.pi rule in rex/init.lua.
 */
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

/**
 * Flags that shape the next run, with the number of values each one takes.
 * Every other flag is dropped: those that pick a session or add a prompt,
 * those that carry a secret or change the output mode, and those not named
 * here.
 */
export const keptFlags = new Map<string, number>([
	["--provider", 1],
	["--model", 1],
	["--models", 1],
	["--thinking", 1],
	["--tools", 1],
	["-t", 1],
	["--exclude-tools", 1],
	["-xt", 1],
	["--no-tools", 0],
	["-nt", 0],
	["--no-builtin-tools", 0],
	["-nbt", 0],
	["--extension", 1],
	["-e", 1],
	["--no-extensions", 0],
	["-ne", 0],
	["--system-prompt", 1],
	["--append-system-prompt", 1],
	["--skill", 1],
	["--prompt-template", 1],
	["--theme", 1],
	["--use-theme", 1],
	["--tui-mode", 1],
	["--no-skills", 0],
	["-ns", 0],
	["--no-prompt-templates", 0],
	["-np", 0],
	["--no-themes", 0],
	["--no-context-files", 0],
	["-nc", 0],
	["--no-mcp", 0],
	["--approve", 0],
	["-a", 0],
	["--no-approve", 0],
	["-na", 0],
	["--offline", 0],
	["--verbose", 0],
]);

/**
 * Flags that pick a session or name it, with the number of values each one
 * takes. The resumed run already has its session file, so they are dropped
 * without dropping the run: Rex rejects a program started with a flag the
 * rule does not list.
 */
export const droppedFlags = new Map<string, number>([
	["-c", 0],
	["--continue", 0],
	["-r", 0],
	["--resume", 0],
	["--session", 1],
	["--session-id", 1],
	["--fork", 1],
	["-n", 1],
	["--name", 1],
]);

/** Where the token waits for the next reload of this extension. */
const tokenKey = Symbol.for("pi.program-resume.token");

/** sha256 of the body and the token, as the protocol's mac. */
export function mac(body: string, token: string): string {
	return createHash("sha256").update(`${body}:${token}`).digest("hex");
}

/** The OSC 7577 report that asks Rex to reopen argv in this terminal. */
export function report(options: {
	pid: number;
	time: number;
	token: string;
	argv: string[];
}): string {
	const { pid, time, token, argv } = options;
	const elements = argv.map((arg) => Buffer.from(arg, "utf8").toString("base64"));
	const body = `pid=${pid}:time=${time}:argv=${elements.join(",")}`;
	return `\x1b]7577;${body}:mac=${mac(body, token)}\x1b\\`;
}

/**
 * Takes the token out of env, so the programs pi starts cannot report in this
 * process's place, and keeps it in store: /new, /resume, /fork and /reload
 * load this file again in this process, and only a process-wide store
 * survives that.
 */
export function takeToken(
	env: Record<string, string | undefined>,
	holder: object,
): string | undefined {
	const store = holder as Record<PropertyKey, unknown>;
	const token = env.OSC7577_TOKEN;
	delete env.OSC7577_TOKEN;
	if (token) {
		store[tokenKey] = token;
		return token;
	}
	const held = store[tokenKey];
	return typeof held === "string" && held !== "" ? held : undefined;
}

/** The command that reopens pi on sessionFile, from this process's arguments. */
export function resumeArgv(argv: string[], sessionFile: string): string[] {
	const kept: string[] = [];
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === "--") break;
		if (!arg.startsWith("-")) continue;
		const equals = arg.startsWith("--") ? arg.indexOf("=") : -1;
		const name = equals === -1 ? arg : arg.slice(0, equals);
		const inline = equals === -1 ? undefined : arg.slice(equals + 1);
		const dropped = droppedFlags.get(name);
		if (dropped !== undefined) {
			i += dropped;
			continue;
		}
		const values = keptFlags.get(name);
		if (values === undefined) continue;
		if (inline !== undefined) {
			// pi reads --flag=value only for flags that take a value.
			if (values > 0) kept.push(arg);
			continue;
		}
		kept.push(arg);
		for (let taken = 0; taken < values && i + 1 < argv.length; taken++) {
			kept.push(argv[++i]);
		}
	}
	return ["pi", "--session", sessionFile, ...kept];
}

/**
 * Reports each session file once, and only once it exists: a new session has
 * a path but no file until its first message is written.
 */
export function makeReporter(options: {
	token: string;
	argv: string[];
	pid?: number;
	now?: () => number;
	exists?: (path: string) => boolean;
	write?: (text: string) => void;
}): (sessionFile: string | undefined) => void {
	const {
		token,
		argv,
		pid = process.pid,
		now = Date.now,
		exists = existsSync,
		write = (text: string) => process.stdout.write(text),
	} = options;
	let reported: string | undefined;
	return (sessionFile) => {
		if (!sessionFile || sessionFile === reported) return;
		if (!exists(sessionFile)) return;
		write(
			report({
				pid,
				time: Math.floor(now() / 1000),
				token,
				argv: resumeArgv(argv, sessionFile),
			}),
		);
		reported = sessionFile;
	};
}

export default function (pi: ExtensionAPI) {
	const token = takeToken(process.env, globalThis);
	if (!token) return;

	// Rex drops the record when the process exits, so this reports once per
	// session file the process opens.
	const reportSession = makeReporter({ token, argv: process.argv.slice(2) });

	const reportCurrent = (ctx: ExtensionContext) => {
		if (ctx.mode !== "tui") return;
		reportSession(ctx.sessionManager.getSessionFile());
	};

	pi.on("session_start", (_event, ctx) => reportCurrent(ctx));
	// turn_end is the first event after the session manager writes an entry.
	pi.on("turn_end", (_event, ctx) => reportCurrent(ctx));
}
