// Pure decision-mapping helpers for the Pi tmux guard extension.
//
// Plain ESM so `node --test` can exercise them on any Node that runs the
// extension host, without a compile step.  The actual decision core is
// scripts/tmux-guard (Python); this module only resolves it, prefilters,
// invokes it, and maps its output onto Pi's `tool_call` result.

import { existsSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const GUARD_TOOLS = new Set(["bash", "powershell"]);

/**
 * Locate the decision core.  Tries, in order: an explicit override, this
 * checkout (resolved through symlinks, so an installed extension still finds
 * its repo), then the installed ~/.local/bin link.  Returns null when none
 * exists, which the handler treats as fail-closed for guarded commands.
 */
export function findGuard({ importMetaUrl, env = process.env } = {}) {
  const candidates = [];
  if (env.DOTFILES_TMUX_GUARD) candidates.push(env.DOTFILES_TMUX_GUARD);
  if (importMetaUrl) {
    try {
      const here = realpathSync(dirname(fileURLToPath(importMetaUrl)));
      candidates.push(resolve(here, "..", "..", "..", "..", "scripts", "tmux-guard"));
    } catch {
      // import.meta.url is unavailable in some loaders; fall through.
    }
  }
  if (env.HOME) candidates.push(join(env.HOME, ".local", "bin", "tmux-guard"));
  for (const candidate of candidates) {
    try {
      if (existsSync(candidate)) return candidate;
    } catch {
      // ignore unreadable candidates
    }
  }
  return null;
}

/** Cheap superset of the core's triggers: skip the process spawn when nothing matches. */
export function needsGuard(command) {
  return /tmux|pkill|killall/i.test(String(command ?? ""));
}

/**
 * Parse the core's one-line protocol.
 * @returns {{kind: "allow"} | {kind: "ask", reason: string} | null}
 */
export function parseDecision(stdout) {
  const text = String(stdout ?? "").trim();
  if (text === "allow") return { kind: "allow" };
  if (text.startsWith("ask\t")) return { kind: "ask", reason: text.slice(4) };
  return null;
}

function deny(reason) {
  return { kind: "deny", reason };
}

/**
 * Ask the core about a command.  Any failure -- missing executable, non-zero
 * exit, bad output -- denies; it never falls back to allowing.
 */
export async function evaluate({ command, cwd, runCore }) {
  if (!needsGuard(command)) return { kind: "allow" };
  let result;
  try {
    result = await runCore(command, cwd);
  } catch (error) {
    return deny(`tmux guard could not run: ${error?.message ?? error}`);
  }
  if (!result || result.code !== 0) {
    const detail = String(result?.stderr ?? "").trim();
    return deny(`tmux guard failed (exit ${result?.code ?? "none"})${detail ? `: ${detail}` : ""}`);
  }
  const decision = parseDecision(result.stdout);
  if (!decision) return deny("tmux guard returned an unreadable decision");
  return decision;
}

/**
 * Build the `tool_call` handler.  `runCore(command, cwd)` must resolve to
 * `{code, stdout, stderr}` and is injected so tests can stub the process.
 */
export function createToolCallHandler({ runCore }) {
  return async function handleToolCall(event, ctx) {
    if (!GUARD_TOOLS.has(event?.toolName)) return undefined;
    const input = event?.input;
    const command = input && typeof input.command === "string" ? input.command : "";
    if (!command.trim()) return undefined;

    const decision = await evaluate({ command, cwd: ctx?.cwd ?? process.cwd(), runCore });
    if (decision.kind === "allow") return undefined;
    if (decision.kind === "deny") return { block: true, reason: decision.reason };

    if (!ctx?.hasUI || typeof ctx?.ui?.confirm !== "function") {
      return {
        block: true,
        reason: `${decision.reason} (no UI available, so the call is blocked)`,
      };
    }
    let approved = false;
    try {
      approved = await ctx.ui.confirm(
        "Destructive tmux command",
        `${command}\n\n${decision.reason}`,
      );
    } catch (error) {
      return {
        block: true,
        reason: `tmux guard could not ask for approval: ${error?.message ?? error}`,
      };
    }
    return approved ? undefined : { block: true, reason: "Blocked by user" };
  };
}

/** Register the guard on a Pi ExtensionAPI-compatible object. */
export function registerTmuxGuard(pi, { runCore }) {
  pi.on("tool_call", createToolCallHandler({ runCore }));
}
