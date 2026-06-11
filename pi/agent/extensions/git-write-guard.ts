import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type GitWriteGuardGlobalState = {
  token?: symbol;
};

type AskUserQuestionParams = {
  questions: Array<{
    question: string;
    header: string;
    options: Array<{
      label: string;
      description: string;
      preview?: string;
    }>;
    multiSelect?: boolean;
  }>;
};

type AskUserQuestionAnswer = {
  questionIndex: number;
  question: string;
  kind: "option" | "custom" | "chat" | "multi";
  answer: string | null;
  selected?: string[];
  notes?: string;
  preview?: string;
};

type AskUserQuestionResult = {
  answers: AskUserQuestionAnswer[];
  cancelled: boolean;
  error?: string;
};

type AskUserBridgeResponse = {
  id?: unknown;
  result?: AskUserQuestionResult;
  error?: string;
};

// Stable bridge target for rpiv-ask-user-question or a companion bridge extension.
// If no provider accepts the request quickly, this guard falls back to ctx.ui.select().
const RPIV_ASK_USER_REQUEST_EVENT = "rpiv:ask-user:request";
const RPIV_ASK_USER_ACCEPTED_EVENT = "rpiv:ask-user:accepted";
const RPIV_ASK_USER_RESPONSE_EVENT = "rpiv:ask-user:response";
const RPIV_ACCEPT_TIMEOUT_MS = 100;
const RPIV_RESPONSE_TIMEOUT_MS = 30 * 60 * 1000;

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

function isBridgeResponse(data: unknown, id: string): data is AskUserBridgeResponse {
  return !!data && typeof data === "object" && (data as AskUserBridgeResponse).id === id;
}

function buildApprovalQuestion(command: string, blockedCommand: string): AskUserQuestionParams {
  const preview = `\`\`\`sh\n${command}\n\`\`\``;
  return {
    questions: [
      {
        question: `Allow this ${blockedCommand} command once?`,
        header: "Git write",
        options: [
          {
            label: "Allow once",
            description: "Run this git write command one time, then require approval again next time.",
            preview,
          },
          {
            label: "Block",
            description: "Keep this git write command blocked.",
            preview,
          },
        ],
      },
    ],
  };
}

async function askWithRpivBridge(
  pi: ExtensionAPI,
  command: string,
  blockedCommand: string
): Promise<boolean | undefined> {
  const id = `git-write-guard-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const params = buildApprovalQuestion(command, blockedCommand);

  return new Promise((resolve) => {
    let settled = false;
    let accepted = false;
    let acceptTimer: ReturnType<typeof setTimeout> | undefined;
    let responseTimer: ReturnType<typeof setTimeout> | undefined;

    const cleanupCallbacks: Array<() => void> = [];
    const finish = (value: boolean | undefined) => {
      if (settled) return;
      settled = true;
      if (acceptTimer) clearTimeout(acceptTimer);
      if (responseTimer) clearTimeout(responseTimer);
      for (const cleanup of cleanupCallbacks) cleanup();
      resolve(value);
    };

    cleanupCallbacks.push(
      pi.events.on(RPIV_ASK_USER_ACCEPTED_EVENT, (data) => {
        if (!isBridgeResponse(data, id)) return;
        accepted = true;
        if (acceptTimer) clearTimeout(acceptTimer);
        responseTimer = setTimeout(() => finish(false), RPIV_RESPONSE_TIMEOUT_MS);
      })
    );

    cleanupCallbacks.push(
      pi.events.on(RPIV_ASK_USER_RESPONSE_EVENT, (data) => {
        if (!isBridgeResponse(data, id)) return;
        const answer = data.result?.answers[0];
        finish(!data.result?.cancelled && answer?.kind === "option" && answer.answer === "Allow once");
      })
    );

    acceptTimer = setTimeout(() => {
      if (!accepted) finish(undefined);
    }, RPIV_ACCEPT_TIMEOUT_MS);

    pi.events.emit(RPIV_ASK_USER_REQUEST_EVENT, {
      id,
      source: "git-write-guard",
      params,
    });
  });
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

    const bridgeChoice = await askWithRpivBridge(pi, command, blockedCommand);
    if (bridgeChoice === true) return undefined;
    if (bridgeChoice === false) return { block: true, reason: `${blockedCommand} blocked by user` };

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
