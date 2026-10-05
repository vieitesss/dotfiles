// Pure helpers for the Pi tmux guard: resolve scripts/tmux-guard, run it for
// tmux commands, and map its answer onto `tool_call`.  Plain ESM for `node --test`.

import { existsSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Locate scripts/tmux-guard: this checkout first (through symlinks), then ~/.local/bin.
export function findGuard({ importMetaUrl, env = process.env } = {}) {
  const candidates = [];
  try {
    const here = realpathSync(dirname(fileURLToPath(importMetaUrl)));
    candidates.push(resolve(here, "..", "..", "..", "..", "scripts", "tmux-guard"));
  } catch {
    // no usable import.meta.url: fall back to the installed path below.
  }
  if (env.HOME) candidates.push(join(env.HOME, ".local", "bin", "tmux-guard"));
  return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

export function needsGuard(command) {
  return /tmux/i.test(String(command ?? ""));
}

export function parseDecision(stdout) {
  const text = String(stdout ?? "").trim();
  if (text === "allow") return { kind: "allow" };
  return text.startsWith("ask\t") ? { kind: "ask", reason: text.slice(4) } : null;
}

// A missing guard, a non-zero exit, or bad output denies; it never allows.
export async function evaluate({ command, cwd, runCore }) {
  if (!needsGuard(command)) return { kind: "allow" };
  let result;
  try {
    result = await runCore(command, cwd);
  } catch (error) {
    return { kind: "deny", reason: `tmux guard could not run: ${error?.message ?? error}` };
  }
  if (!result || result.code !== 0) {
    const detail = String(result?.stderr ?? "").trim();
    return { kind: "deny", reason: `tmux guard failed (exit ${result?.code ?? "none"})${detail && `: ${detail}`}` };
  }
  return parseDecision(result.stdout) ?? { kind: "deny", reason: "tmux guard returned an unreadable decision" };
}

// Allow, block, or ask the human through ctx.ui.confirm.
export function createToolCallHandler({ runCore }) {
  return async function handleToolCall(event, ctx) {
    const tool = event?.toolName;
    if (tool !== "bash" && tool !== "powershell") return undefined;
    const command = typeof event?.input?.command === "string" ? event.input.command : "";
    if (!command.trim()) return undefined;

    const decision = await evaluate({ command, cwd: ctx?.cwd ?? process.cwd(), runCore });
    if (decision.kind === "allow") return undefined;
    if (decision.kind === "deny") return { block: true, reason: decision.reason };
    if (!ctx?.hasUI || typeof ctx?.ui?.confirm !== "function") {
      return { block: true, reason: `${decision.reason} (no UI available, so the call is blocked)` };
    }
    try {
      const approved = await ctx.ui.confirm(
        "Tmux command needs approval",
        `${command}\n\n${decision.reason}`,
      );
      return approved ? undefined : { block: true, reason: "Blocked by user" };
    } catch (error) {
      return { block: true, reason: `tmux guard could not ask for approval: ${error?.message ?? error}` };
    }
  };
}
