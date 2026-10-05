/**
 * Tmux destructive-command guard.
 *
 * Blocks agent-issued destructive tmux operations (kill-server, kill-session,
 * broad kill-window/kill-pane, source-file, ...) unless they target a socket an
 * owned tmux-sandbox run created, or a human approves the exact call.  The
 * decision core is scripts/tmux-guard (Python); this adapter only wires it into
 * Pi.  See docs/tmux-guard.md.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { findGuard, registerTmuxGuard } from "./core.mjs";

export default function (pi: ExtensionAPI) {
	const guard = findGuard({ importMetaUrl: import.meta.url });
	registerTmuxGuard(pi, {
		runCore: async (command: string, cwd: string) => {
			if (!guard) {
				return { code: 127, stdout: "", stderr: "tmux-guard executable not found" };
			}
			const result = await pi.exec(guard, ["--cwd", cwd, "--", command], { timeout: 5000 });
			return { code: result.code, stdout: result.stdout, stderr: result.stderr };
		},
	});
}
