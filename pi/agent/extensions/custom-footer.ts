import { execFileSync } from "node:child_process";
import { isAbsolute, relative, resolve, sep as pathSep } from "node:path";
import { truncateToWidth, visibleWidth, type Component } from "@earendil-works/pi-tui";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function formatTokens(count: number | null | undefined): string {
  if (count == null) return "?";
  if (count < 1000) return String(count);
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
  return `${Math.round(count / 1000000)}M`;
}

function formatCwd(cwd: string): string {
  const home = process.env.HOME || process.env.USERPROFILE;
  if (!home) return cwd;

  const resolvedCwd = resolve(cwd);
  const resolvedHome = resolve(home);
  const rel = relative(resolvedHome, resolvedCwd);
  const inHome = rel === "" || (rel !== ".." && !rel.startsWith(`..${pathSep}`) && !isAbsolute(rel));
  return inHome ? (rel === "" ? "~" : `~${pathSep}${rel}`) : resolvedCwd;
}

function gitBranch(cwd: string): string {
  try {
    return execFileSync("git", ["branch", "--show-current"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 200,
    }).trim();
  } catch {
    return "";
  }
}

export default function (pi: ExtensionAPI) {
  let model: any;
  let thinking = "off";

  pi.on("session_start", (_event, ctx) => {
    model = ctx.model ?? model;
    thinking = pi.getThinkingLevel();

    ctx.ui.setFooter((_tui, theme): Component => ({
      render(width: number): string[] {
        const cwd = formatCwd(ctx.cwd);
        const branch = gitBranch(ctx.cwd);
        const sep = "";

        const usage = ctx.getContextUsage();
        const amount = formatTokens(usage?.tokens);
        const percent = usage?.percent == null ? "?" : `${usage.percent.toFixed(1)}%`;
        const left = [
          theme.fg("mdHeading", amount),
          theme.fg("dim", percent),
        ].join(` ${theme.fg("dim", sep)} `);
        const middle = [
          theme.fg("dim", cwd),
          branch ? theme.fg("dim", branch) : "",
        ].filter(Boolean).join(` ${theme.fg("dim", sep)} `);

        const modelName = model?.id ?? "no-model";
        const effort = model?.reasoning ? thinking || "off" : "off";
        const right = theme.fg("dim", `${modelName} ${sep} ${effort}`);
        const leftWidth = visibleWidth(left);
        const middleWidth = visibleWidth(middle);
        const rightWidth = visibleWidth(right);
        const free = width - leftWidth - middleWidth - rightWidth;
        let line: string;
        if (free >= 2) {
          const leftPad = Math.floor(free / 2);
          const rightPad = free - leftPad;
          line = `${left}${" ".repeat(leftPad)}${middle}${" ".repeat(rightPad)}${right}`;
        } else {
          line = truncateToWidth(`${left} ${theme.fg("dim", "")} ${middle} ${right}`, width, "…");
        }

        return [line];
      },
      invalidate() {},
    }));
  });

  pi.on("model_select", (event) => {
    model = event.model;
  });

  pi.on("thinking_level_select", (event) => {
    thinking = event.level;
  });

  pi.on("session_shutdown", (_event, ctx) => {
    ctx.ui.setFooter(undefined);
  });
}
