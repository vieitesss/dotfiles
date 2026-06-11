import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type GitWriteGuardGlobalState = {
  token?: symbol;
};

const gitWriteGuardGlobal = globalThis as typeof globalThis & { __piGitWriteGuard?: GitWriteGuardGlobalState };
const gitWriteGuardState = (gitWriteGuardGlobal.__piGitWriteGuard ??= {});

const blockedGitCommands = new Set(["commit", "push"]);
const gitOptionsWithValue = new Set([
  "-C",
  "-c",
  "--git-dir",
  "--work-tree",
  "--namespace",
  "--exec-path",
  "--config-env",
  "--super-prefix",
]);
const gitOptionsWithoutValue = new Set([
  "--bare",
  "--literal-pathspecs",
  "--no-optional-locks",
  "--no-pager",
  "--paginate",
]);
const gitOptionsWithValuePrefixes = Array.from(gitOptionsWithValue, (option) => `${option}=`);

function shellWords(input: string): string[] {
  const words: string[] = [];
  let word = "";
  let quote: "'" | '"' | undefined;
  let escaping = false;

  for (const char of input) {
    if (escaping) {
      word += char;
      escaping = false;
      continue;
    }

    if (char === "\\" && quote !== "'") {
      escaping = true;
      continue;
    }

    if (quote) {
      if (char === quote) quote = undefined;
      else word += char;
      continue;
    }

    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }

    if (/\s|[;&|(){}]/.test(char)) {
      if (word) {
        words.push(word);
        word = "";
      }
      continue;
    }

    word += char;
  }

  if (word) words.push(word);
  return words;
}

function isGitExecutable(word: string): boolean {
  return word === "git" || word.endsWith("/git");
}

function skipGitGlobalOptions(words: string[], gitIndex: number): number {
  let index = gitIndex + 1;

  while (index < words.length) {
    const word = words[index];

    if (gitOptionsWithValue.has(word)) {
      index += 2;
      continue;
    }

    if (word.startsWith("-C") && word.length > 2) {
      index += 1;
      continue;
    }

    if (word.startsWith("-c") && word.length > 2) {
      index += 1;
      continue;
    }

    if (gitOptionsWithValuePrefixes.some((option) => word.startsWith(option))) {
      index += 1;
      continue;
    }

    if (gitOptionsWithoutValue.has(word)) {
      index += 1;
      continue;
    }

    return index;
  }

  return index;
}

function findBlockedGitCommand(command: string): string | undefined {
  const words = shellWords(command);

  for (let index = 0; index < words.length; index += 1) {
    const word = words[index];

    // Catch nested shell snippets, e.g. bash -lc "git push".
    if (!isGitExecutable(word) && word.includes("git ")) {
      const nested = findBlockedGitCommand(word);
      if (nested) return nested;
    }

    if (!isGitExecutable(word)) continue;

    const subcommandIndex = skipGitGlobalOptions(words, index);
    const subcommand = words[subcommandIndex];

    if (subcommand && blockedGitCommands.has(subcommand)) return `git ${subcommand}`;
  }

  return undefined;
}

export default function (pi: ExtensionAPI) {
  const token = Symbol("pi-git-write-guard-load");
  gitWriteGuardState.token = token;
  const isCurrentLoad = () => gitWriteGuardState.token === token;

  pi.on("tool_call", async (event, ctx) => {
    if (!isCurrentLoad()) return undefined;
    if (event.toolName !== "bash") return undefined;

    const command = event.input.command;
    if (typeof command !== "string") return undefined;

    const blockedCommand = findBlockedGitCommand(command);
    if (!blockedCommand) return undefined;

    if (!ctx.hasUI) {
      return {
        block: true,
        reason: `${blockedCommand} blocked: explicit user approval required`,
      };
    }

    pi.events.emit("unipi:approval:needed", {
      kind: "git",
      command,
      blockedCommand,
    });

    const choice = await ctx.ui.select(
      `Git write command needs explicit approval.\n\n${command}\n\nAllow this ${blockedCommand} command once?`,
      ["Allow once", "Block"]
    );

    if (choice !== "Allow once") {
      return { block: true, reason: `${blockedCommand} blocked by user` };
    }

    return undefined;
  });
}
