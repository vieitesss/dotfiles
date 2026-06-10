import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir, platform } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

function appleScriptString(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function sendNativeNotification(title: string, message: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const system = platform();

    if (system === "darwin") {
      execFile(
        "osascript",
        ["-e", `display notification ${appleScriptString(message)} with title ${appleScriptString(title)}`],
        (error) => (error ? reject(error) : resolve())
      );
      return;
    }

    if (system === "linux") {
      execFile("notify-send", [title, message], (error) => (error ? reject(error) : resolve()));
      return;
    }

    reject(new Error(`Unsupported notification platform: ${system}`));
  });
}

function shouldNotifyAgentEnd(): boolean {
  const configPath = join(homedir(), ".unipi", "config", "notify", "config.json");

  if (!existsSync(configPath)) return true;

  try {
    const config = JSON.parse(readFileSync(configPath, "utf8"));
    if (config?.native?.enabled === false) return false;
    if (config?.events?.agent_end?.enabled === false) return false;
    return true;
  } catch {
    return true;
  }
}

async function notifyTest(ctx?: ExtensionContext): Promise<void> {
  try {
    await sendNativeNotification("Pi notify test", "Notifications are working");
    ctx?.ui.notify("Sent native notification", "info");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    ctx?.ui.notify(`Notification failed: ${message}`, "error");
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("unipi:notify-test", {
    description: "Send a native notification test",
    handler: async (_args: string, ctx: ExtensionContext) => notifyTest(ctx),
  });

  pi.registerCommand("notify-test", {
    description: "Send a native notification test",
    handler: async (_args: string, ctx: ExtensionContext) => notifyTest(ctx),
  });

  pi.on("agent_end", async () => {
    if (!shouldNotifyAgentEnd()) return;
    await sendNativeNotification("Pi — Agent Complete", "Agent is complete").catch(() => undefined);
  });
}
