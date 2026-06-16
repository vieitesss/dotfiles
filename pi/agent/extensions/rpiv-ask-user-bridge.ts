import { homedir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const RPIV_PACKAGE_ROOT = `${homedir()}/.pi/agent/npm/node_modules/@juicesharp/rpiv-ask-user-question`;
const RPIV_ASK_USER_REQUEST_EVENT = "rpiv:ask-user:request";
const RPIV_ASK_USER_ACCEPTED_EVENT = "rpiv:ask-user:accepted";
const RPIV_ASK_USER_RESPONSE_EVENT = "rpiv:ask-user:response";

type QuestionParams = {
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

type QuestionnaireResult = {
  answers: Array<{
    questionIndex: number;
    question: string;
    kind: "option" | "custom" | "chat" | "multi";
    answer: string | null;
    selected?: string[];
    notes?: string;
    preview?: string;
  }>;
  cancelled: boolean;
  error?: string;
};

type AskUserRequest = {
  id?: unknown;
  source?: unknown;
  params?: unknown;
};

type RpivModules = {
  validateQuestionnaire: (params: QuestionParams) => { ok: true } | { ok: false; message: string; error: string };
  buildItemsForQuestion: (question: QuestionParams["questions"][number]) => unknown[];
  buildToolResult: (text: string, details: QuestionnaireResult) => unknown;
  QuestionnaireSession: new (args: {
    tui: unknown;
    theme: unknown;
    params: QuestionParams;
    itemsByTab: unknown[][];
    done: (value: QuestionnaireResult) => void;
  }) => { component: unknown };
};

type RpivBridgeGlobalState = {
  token?: symbol;
};

const rpivBridgeGlobal = globalThis as typeof globalThis & { __piRpivAskUserBridge?: RpivBridgeGlobalState };
const rpivBridgeState = (rpivBridgeGlobal.__piRpivAskUserBridge ??= {});

let modulesPromise: Promise<RpivModules> | undefined;

function isQuestionParams(value: unknown): value is QuestionParams {
  if (!value || typeof value !== "object") return false;
  const questions = (value as QuestionParams).questions;
  return Array.isArray(questions) && questions.length > 0;
}

function isRequest(value: unknown): value is AskUserRequest {
  return !!value && typeof value === "object";
}

function loadRpivModules(): Promise<RpivModules> {
  modulesPromise ??= Promise.all([
    import(`${RPIV_PACKAGE_ROOT}/ask-user-question.ts`),
    import(`${RPIV_PACKAGE_ROOT}/tool/validate-questionnaire.ts`),
    import(`${RPIV_PACKAGE_ROOT}/tool/response-envelope.ts`),
    import(`${RPIV_PACKAGE_ROOT}/state/questionnaire-session.ts`),
  ]).then(([ask, validate, response, session]) => ({
    validateQuestionnaire: validate.validateQuestionnaire,
    buildItemsForQuestion: ask.buildItemsForQuestion,
    buildToolResult: response.buildToolResult,
    QuestionnaireSession: session.QuestionnaireSession,
  }));
  return modulesPromise;
}

async function handleRequest(pi: ExtensionAPI, ctx: ExtensionContext, data: unknown): Promise<void> {
  if (!isRequest(data) || typeof data.id !== "string") return;
  if (!isQuestionParams(data.params)) return;

  pi.events.emit(RPIV_ASK_USER_ACCEPTED_EVENT, { id: data.id });

  if (!ctx.hasUI || ctx.mode !== "tui") {
    pi.events.emit(RPIV_ASK_USER_RESPONSE_EVENT, {
      id: data.id,
      result: { answers: [], cancelled: true, error: "no_ui" },
    });
    return;
  }

  try {
    const rpiv = await loadRpivModules();
    const validation = rpiv.validateQuestionnaire(data.params);
    if (!validation.ok) {
      pi.events.emit(RPIV_ASK_USER_RESPONSE_EVENT, {
        id: data.id,
        result: { answers: [], cancelled: true, error: validation.error },
      });
      return;
    }

    const itemsByTab = data.params.questions.map((question) => rpiv.buildItemsForQuestion(question));
    const result = await ctx.ui.custom<QuestionnaireResult>(
      (tui, theme, _kb, done) => {
        const session = new rpiv.QuestionnaireSession({
          tui,
          theme,
          params: data.params as QuestionParams,
          itemsByTab,
          done,
        });
        return session.component as never;
      },
      {
        overlay: true,
        overlayOptions: {
          anchor: "bottom-center",
          width: "100%",
          maxHeight: "100%",
          margin: { left: 0, right: 0, bottom: 0 },
        },
      }
    );

    pi.events.emit(RPIV_ASK_USER_RESPONSE_EVENT, {
      id: data.id,
      result: result ?? { answers: [], cancelled: true },
    });
  } catch (error) {
    pi.events.emit(RPIV_ASK_USER_RESPONSE_EVENT, {
      id: data.id,
      result: { answers: [], cancelled: true, error: "bridge_error" },
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

export default function (pi: ExtensionAPI) {
  const token = Symbol("pi-rpiv-ask-user-bridge-load");
  rpivBridgeState.token = token;
  const isCurrentLoad = () => rpivBridgeState.token === token;

  pi.on("session_start", async (_event, ctx) => {
    pi.events.on(RPIV_ASK_USER_REQUEST_EVENT, (data) => {
      if (!isCurrentLoad()) return;
      void handleRequest(pi, ctx, data);
    });
  });
}
