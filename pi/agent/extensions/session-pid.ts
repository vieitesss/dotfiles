/**
 * Records the session file this pi process has open, in
 * ~/.pi/agent/pids/<pid>.json, as Claude Code does in ~/.claude/sessions.
 * rex/snapshot.lua reads it to reopen the same session after the Rex server
 * restarts.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const file = path.join(os.homedir(), ".pi", "agent", "pids", `${process.pid}.json`);

export default function (pi: ExtensionAPI) {
	// Fires again on /new, /resume, /fork and /reload, so the record follows
	// the session the process has open.
	pi.on("session_start", (_event, ctx) => {
		if (ctx.mode !== "tui") return;
		const sessionFile = ctx.sessionManager.getSessionFile();
		try {
			fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(file, JSON.stringify({ sessionFile }) + "\n");
		} catch {}
	});

	pi.on("session_shutdown", (event) => {
		if (event.reason !== "quit") return;
		try {
			fs.unlinkSync(file);
		} catch {}
	});
}
