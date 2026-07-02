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

function loadNotificationConfig(): unknown {
  const configPath = join(homedir(), ".unipi", "config", "notify", "config.json");

  if (!existsSync(configPath)) return undefined;

  try {
    return JSON.parse(readFileSync(configPath, "utf8"));
  } catch {
    return undefined;
  }
}

function shouldNotifyEvent(eventName: string): boolean {
  const config = loadNotificationConfig() as { native?: { enabled?: boolean }; events?: Record<string, { enabled?: boolean }> } | undefined;
  if (config?.native?.enabled === false) return false;
  if (config?.events?.[eventName]?.enabled === false) return false;
  return true;
}

type NotificationGlobalState = {
  token?: symbol;
  recentNotifications: Map<string, number>;
  suppressNextAgentEnd?: boolean;
};

const globalState = globalThis as typeof globalThis & { __piAgentNotifications?: NotificationGlobalState };
const notificationState = (globalState.__piAgentNotifications ??= { recentNotifications: new Map<string, number>() });

function notifyOnce(eventName: string, title: string, message: string): boolean {
  if (!shouldNotifyEvent(eventName)) return false;

  const key = `${eventName}:${title}:${message}`;
  const now = Date.now();
  const lastSent = notificationState.recentNotifications.get(key) ?? 0;
  if (now - lastSent < 2000) return false;
  notificationState.recentNotifications.set(key, now);

  void sendNativeNotification(title, message).catch(() => undefined);
  return true;
}

function notifyWaiting(eventName: string, title: string, message: string): void {
  if (notifyOnce(eventName, title, message)) {
    notificationState.suppressNextAgentEnd = true;
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
  const token = Symbol("pi-agent-notifications-load");
  notificationState.token = token;
  const isCurrentLoad = () => notificationState.token === token;

  pi.registerCommand("unipi:notify-test", {
    description: "Send a native notification test",
    handler: async (_args: string, ctx: ExtensionContext) => notifyTest(ctx),
  });

  pi.registerCommand("notify-test", {
    description: "Send a native notification test",
    handler: async (_args: string, ctx: ExtensionContext) => notifyTest(ctx),
  });

  pi.events.on("rpiv:ask-user:prompt", () => {
    if (!isCurrentLoad()) return;
    notifyWaiting("ask_user_prompt", "Pi — Input Needed", "Question waiting for answer");
  });

  pi.events.on("unipi:approval:needed", (data) => {
    if (!isCurrentLoad()) return;
    const payload = data as { kind?: string; blockedCommand?: string } | undefined;
    const subject = payload?.blockedCommand ?? payload?.kind ?? "approval";
    notifyWaiting("approval_needed", "Pi — Approval Needed", `${subject} waiting for approval`);
  });

  pi.on("agent_end", async () => {
    if (!isCurrentLoad()) return;
    if (notificationState.suppressNextAgentEnd) {
      notificationState.suppressNextAgentEnd = false;
      return;
    }
    notifyOnce("agent_end", "Pi — Agent Complete", "Agent is complete");
  });
}
