/**
 * Reports this pi process to the Program Resume protocol (OSC 7577), so a Rex
 * server restart opens pi again on the session file it has open. Rex accepts
 * the report through the resume.trust.pi rule in rex/init.lua.
 */
import { createHash } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

/**
 * Flags that shape the next run, with the number of values each one takes.
 * Every other flag is dropped: those that pick a session or add a prompt,
 * those that carry a secret or change the output mode, and those not named
 * here.
 */
const keptFlags = new Map<string, number>([
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
]);

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

/** The command that reopens pi on sessionFile, from this process's arguments. */
export function resumeArgv(argv: string[], sessionFile: string): string[] {
	const kept: string[] = [];
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === "--") break;
		if (!arg.startsWith("-")) continue;
		const [name, inline] = arg.startsWith("--") && arg.includes("=")
			? [arg.slice(0, arg.indexOf("=")), arg.slice(arg.indexOf("=") + 1)]
			: [arg, undefined];
		const values = keptFlags.get(name);
		if (values === undefined) continue;
		if (inline !== undefined) {
			kept.push(arg);
			continue;
		}
		kept.push(arg);
		for (let taken = 0; taken < values && i + 1 < argv.length; taken++) {
			kept.push(argv[++i]);
		}
	}
	return ["pi", ...kept, "--session", sessionFile];
}

export default function (pi: ExtensionAPI) {
	// Read the token once and take it out of the environment, so the programs pi
	// starts cannot report in this process's place.
	const token = process.env.OSC7577_TOKEN;
	delete process.env.OSC7577_TOKEN;
	if (!token) return;

	// A new session has no file until its first message is written, so this
	// reports once the file exists and again whenever the process switches to
	// another one. Rex drops the record when the process exits.
	let reported: string | undefined;

	const reportCurrent = (ctx: ExtensionContext) => {
		if (ctx.mode !== "tui") return;
		const sessionFile = ctx.sessionManager.getSessionFile();
		if (!sessionFile || sessionFile === reported) return;
		process.stdout.write(
			report({
				pid: process.pid,
				time: Math.floor(Date.now() / 1000),
				token,
				argv: resumeArgv(process.argv.slice(2), sessionFile),
			}),
		);
		reported = sessionFile;
	};

	pi.on("session_start", (_event, ctx) => reportCurrent(ctx));
	// turn_end is the first event after the session manager writes an entry.
	pi.on("turn_end", (_event, ctx) => reportCurrent(ctx));
}
