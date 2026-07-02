import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

// ponytail: only running/done wired; needs-input skipped, pi handles permissions inline.
const script = join(homedir(), ".tmux/plugins/tmux-agent-indicator/scripts/agent-state.sh");

function setState(state: "running" | "done" | "off") {
  if (!process.env.TMUX) return;
  execFile("bash", [script, "--agent", "pi", "--state", state], () => {});
}

export default function (pi: ExtensionAPI) {
  pi.on("agent_start", () => setState("running"));
  pi.on("agent_end", () => setState("done"));
}
