/**
 * Turns caveman on by default: adds the caveman skill to the system prompt of
 * every run, so it also survives compaction. Mirrors the Claude Code hook in
 * claude/hooks/caveman-session-start.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const skillPath = path.join(os.homedir(), ".agents", "skills", "caveman", "SKILL.md");

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", (event, ctx) => {
		try {
			const skill = fs.readFileSync(skillPath, "utf8");
			event.systemPromptOptions.sections.caveman =
				`Caveman mode is on by default. Follow the caveman skill below from your first reply, until the user turns it off.\n\n${skill}`;
		} catch (error) {
			ctx.ui.notify(`caveman: cannot read ${skillPath}: ${error}`, "warning");
		}
	});
}
