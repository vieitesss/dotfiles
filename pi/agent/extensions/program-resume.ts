/**
 * Reports this pi process to the Program Resume protocol (OSC 7577), so a Rex
 * server restart opens pi again on the session file it has open. Rex accepts
 * the report through the resume.trust.pi rule in rex/init.lua.
 *
 * The report carries no flags: pi sets process.title, which rewrites the OS
 * argv Rex reads back, so a reported flag could never match the one Rex sees
 * and every report would be refused with flags_differ.
 */
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

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

/**
 * The command that reopens pi on sessionFile. It is the session file and
 * nothing else: see the header for why no flag is carried over.
 */
export function resumeCommand(sessionFile: string): string[] {
	return ["pi", "--session", sessionFile];
}

/**
 * Reports each session file once, and only once it exists: a new session has
 * a path but no file until its first message is written.
 */
export function makeReporter(options: {
	token: string;
	pid?: number;
	now?: () => number;
	exists?: (path: string) => boolean;
	write?: (text: string) => void;
}): (sessionFile: string | undefined) => void {
	const {
		token,
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
				argv: resumeCommand(sessionFile),
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
	const reportSession = makeReporter({ token });

	const reportCurrent = (ctx: ExtensionContext) => {
		if (ctx.mode !== "tui") return;
		reportSession(ctx.sessionManager.getSessionFile());
	};

	pi.on("session_start", (_event, ctx) => reportCurrent(ctx));
	// turn_end is the first event after the session manager writes an entry.
	pi.on("turn_end", (_event, ctx) => reportCurrent(ctx));
}
