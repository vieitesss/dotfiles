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

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (!isToolCallEventType("bash", event)) return;
		const { command, timeout } = event.input;
		if (!startsNvim.test(command)) return;
		const problems: string[] = [];
		if (!exits.test(command)) {
			problems.push("the command never quits Neovim (use `nvim -l script.lua`, or end with -c 'qa!' / +qa!)");
		}
		if (typeof timeout !== "number" || timeout <= 0 || timeout > maxSeconds) {
			problems.push(`set the bash tool's timeout to at most ${maxSeconds} seconds`);
		}
		if (problems.length === 0) return;
		return {
			block: true,
			reason:
				"Blocked: a Neovim command must exit on its own. " +
				problems.join("; ") +
				". Prefer the repo's test runner (go test / just test), which has its own timeout.",
		};
	});
}
