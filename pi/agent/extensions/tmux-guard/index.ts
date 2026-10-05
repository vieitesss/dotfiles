// Pi tmux guard: screens shell commands that mention tmux with scripts/tmux-guard
// (TypeSafe Jev, best effort).  Risky or uncertain commands ask the human; guard
// failures block.  See docs/tmux-guard.md.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createToolCallHandler, findGuard } from "./core.mjs";

export default function (pi: ExtensionAPI) {
	const guard = findGuard({ importMetaUrl: import.meta.url });
	pi.on(
		"tool_call",
		createToolCallHandler({
			runCore: async (command: string, cwd: string) => {
				if (!guard) return { code: 127, stdout: "", stderr: "tmux-guard executable not found" };
				// Above the guard's own 3s TypeSafe timeout, so a slow screen comes back as
				// an ask instead of being killed into a hard block.
				const result = await pi.exec(guard, ["--cwd", cwd, "--", command], { timeout: 8000 });
				return { code: result.code, stdout: result.stdout, stderr: result.stderr };
			},
		}),
	);
}
