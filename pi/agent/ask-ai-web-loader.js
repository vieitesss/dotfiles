import { homedir } from "node:os";
import { join } from "node:path";

// pi-web-extension imports jsdom and turndown at module load time even when
// its tools are inactive. Keep those dependencies out of the normal Ask-AI
// startup path; the package is loaded only for a prompt that needs the web.
const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
const webExtension = join(agentDir, "npm", "node_modules", "pi-web-extension", "index.ts");
const webTools = ["websearch", "webfetch"];

let webExtensionLoaded = false;
let webExtensionLoad;

function looksLikeUrlPrompt(prompt) {
  return /(https?:\/\/\S+|www\.\S+)/i.test(prompt);
}

function looksLikeWebSearchPrompt(prompt) {
  const text = prompt.toLowerCase();
  const patterns = [
    /\b(search the web|look online|find online|search online|web search)\b/,
    /\b(official documentation|official docs|api docs|api reference)\b/,
    /\b(latest version|latest release|release notes|what's new)\b/,
    /\b(current price|current status|today's|yesterday's|this week's)\b/,
    /\bnews about\b/,
    /\bwhat changed in\b/,
    /\bup to date\b/,
    /\bon the web\b/,
    /\bgoogle\s+(for|how|what|why|when)\b/,
    /\b(find|look up|check)\s+.{0,20}\b(online|on the web|on the internet)\b/,
  ];
  return patterns.some((pattern) => pattern.test(text));
}

function setWebToolsActive(pi, enabled) {
  const active = new Set(pi.getActiveTools());
  for (const tool of webTools) {
    if (enabled) active.add(tool);
    else active.delete(tool);
  }
  pi.setActiveTools([...active]);
}

async function loadWebExtension(pi) {
  webExtensionLoad ??= import(webExtension).then(({ default: extension }) => {
    extension(pi);
    webExtensionLoaded = true;
  });
  await webExtensionLoad;
}

export default function askAiWebLoader(pi) {
  pi.on("session_start", () => {
    setWebToolsActive(pi, false);
  });

  pi.on("before_agent_start", async (event) => {
    // Once loaded, let pi-web-extension's own handler manage later prompts.
    if (webExtensionLoaded) return;

    const hasUrl = looksLikeUrlPrompt(event.prompt);
    const likelyNeedsWeb = looksLikeWebSearchPrompt(event.prompt);
    if (!hasUrl && !likelyNeedsWeb) {
      setWebToolsActive(pi, false);
      return;
    }

    await loadWebExtension(pi);
    setWebToolsActive(pi, true);

    const instructions = [];
    if (hasUrl) {
      instructions.push("The prompt includes a URL. Use webfetch before answering about that page.");
    }
    if (likelyNeedsWeb) {
      instructions.push("The prompt likely needs external or current info. Prefer websearch over memory.");
    }

    return {
      systemPrompt:
        event.systemPrompt +
        "\n\n## pi-web steering\n" +
        instructions.map((line) => `- ${line}`).join("\n"),
    };
  });
}
