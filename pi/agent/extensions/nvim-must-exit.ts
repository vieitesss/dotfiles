/**
 * Blocks bash calls that start Neovim without a way out. A headless nvim
 * that never quits hangs the agent until someone kills it.
 *
 * A call that runs nvim is allowed only when both hold:
 * - the command exits Neovim: `nvim -l script`, or a `qa`/`qall`/`cq`
 *   command (e.g. `-c 'qa!'`, `+qa`), or `--version`/`-v`/`-h`;
 * - the bash call sets its timeout, at most 120 seconds.
 * Test runners that start nvim themselves (go test, just test) are not
 * matched: they carry their own timeouts.
 */
import { type ExtensionAPI, isToolCallEventType } from "@earendil-works/pi-coding-agent";

// nvim in command position: line start, after ; & | ( ` or $(, past
// any VAR=value prefixes, as a bare name or a path.
const startsNvim = /(^|[;&|(`]|\$\()\s*(\w+=\S*\s+)*(exec\s+)?(\S*\/)?nvim(?=\s|$)/m;
const exits = /(\s-l\s|\bqa!?\b|\bqall!?\b|\bcq!?\b|\bqa(ll)?!?['"]|\s--version\b|\s-v\b|\s-h\b|\s--help\b)/;
const maxSeconds = 120;

// Heredoc bodies (after `<<WORD`, `<<'WORD'`, `<<"WORD"`, `<<-WORD`) are data,
// not commands: drop them through the terminating line.
function withoutHeredocs(command: string): string {
	const kept: string[] = [];
	const pending: { word: string; tabs: boolean }[] = [];
	for (const line of command.split("\n")) {
		const body = pending[0];
		if (body) {
			if ((body.tabs ? line.replace(/^\t+/, "") : line).trim() === body.word) pending.shift();
			continue;
		}
		kept.push(line);
		for (const m of line.matchAll(/<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|(\w+))/g)) {
			const word = m[2] ?? m[3] ?? m[4];
			if (word !== undefined) pending.push({ word, tabs: m[1] === "-" });
		}
	}
	return kept.join("\n");
}

// Quoted strings (`git commit -m "..."`, `echo '...'`) are data too, so drop
// their contents before looking for nvim in command position. The exit check
// still reads the original command: `-c 'qa!'` lives inside quotes.
function stripData(command: string): string {
	return withoutHeredocs(command).replace(/'(?:[^']*)'|"(?:[^"\\]|\\.)*"/g, " ");
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (!isToolCallEventType("bash", event)) return;
		const { command, timeout } = event.input;
		const reason = check(command, timeout);
		if (reason === undefined) return;
		return { block: true, reason };
	});
}

/** Returns the block reason, or undefined when the call is allowed. */
export function check(command: string, timeout: number | undefined): string | undefined {
	if (!startsNvim.test(stripData(command))) return undefined;
	const problems: string[] = [];
	if (!exits.test(command)) {
		problems.push("the command never quits Neovim (use `nvim -l script.lua`, or end with -c 'qa!' / +qa!)");
	}
	if (typeof timeout !== "number" || timeout <= 0 || timeout > maxSeconds) {
		problems.push(`set the bash tool's timeout to at most ${maxSeconds} seconds`);
	}
	if (problems.length === 0) return undefined;
	return (
		"Blocked: a Neovim command must exit on its own. " +
		problems.join("; ") +
		". Prefer the repo's test runner (go test / just test), which has its own timeout."
	);
}
