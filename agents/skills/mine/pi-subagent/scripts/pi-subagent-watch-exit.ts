import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Watch-pane companion for pi-subagent.sh.
 *
 * The child runs in a tmux pane as the real pi TUI. Once the agent run is
 * fully settled (no retry, compaction, or queued continuation pending),
 * gracefully shut pi down so the runner sees a normal exit and can finish
 * the turn (artifacts, exit code, busy marker). The pane's terminal is
 * restored by pi's normal shutdown path (no raw-mode residue).
 */
export default function (pi: ExtensionAPI) {
  let shuttingDown = false;
  pi.on("agent_settled", async (_event, ctx) => {
    if (shuttingDown) return;
    shuttingDown = true;
    ctx.shutdown();
  });
}
