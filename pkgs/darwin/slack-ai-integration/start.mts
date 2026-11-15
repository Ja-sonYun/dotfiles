import {
  errorMessage,
  hasErrorCode,
  isRecord,
  parseRequest,
} from "./summary/contracts.mjs";
import type {
  ThreadIdentity,
  SummaryCard,
  StoredCard,
  SummaryResult,
} from "./summary/contracts.mjs";
interface SummarySession {
  id: string;
  controller: AbortController;
  contextId: number;
  key: string;
  progress: string;
}
type SummaryListener = (
  thread: ThreadIdentity,
  card?: StoredCard,
  deletedId?: string,
  error?: string,
  jobId?: string,
) => Promise<void>;
import { requiredSetting } from "./process.mjs";
import { configureServiceLog } from "./log.mjs";
import {
  parseTargets,
  parseBinding,
  parseMessage,
  evaluationValue,
} from "./protocol.mjs";
import type { DebugTarget, BindingEvent, PendingCall } from "./protocol.mjs";
import { mkdir, readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { summarize } from "./summary/summarize.mjs";
import { SummaryStore, threadKey } from "./summary/store.mjs";

import { parseRequest as parseReviewRequest } from "./review/contracts.mjs";
import type {
  ReviewContext,
  ProtectedElement,
  ReviewHistory,
  ReviewResult,
  ClassificationResult,
} from "./review/contracts.mjs";
import { review } from "./review/review.mjs";
import { classify } from "./review/classify.mjs";
import { TaskQueue } from "./tasks.mjs";
import { TaskStore } from "./task-store.mjs";
import type { StoredReviewSnapshot } from "./review/contracts.mjs";
import type { TaskEntry, TaskView } from "./tasks.mjs";
import type { ToolEvent } from "./codex.mjs";

interface ReviewSession {
  id: string;
  original: string;
  context: ReviewContext;
  protectedElements: ProtectedElement[];
  history: ReviewHistory[];
  contextId: number;
  controller?: AbortController | undefined;
  response?:
    | {
        receiver: "receive" | "receiveClassification";
        turn: number;
        result: ReviewResult | ClassificationResult;
      }
    | undefined;
}

const endpoint = "http://127.0.0.1:9222";
const reviewEnabled = process.env.SLACK_AI_MESSAGE_REVIEW_ENABLED === "true";
const summaryEnabled = process.env.SLACK_AI_THREAD_SUMMARY_ENABLED === "true";
const workspaceId = process.env.SLACK_AI_WORKSPACE_ID || null;
const disableSend = process.env.SLACK_AI_DISABLE_SEND === "true";
if (workspaceId !== null && !/^T[A-Z0-9]+$/.test(workspaceId))
  throw new Error("SLACK_AI_WORKSPACE_ID must be a Slack workspace ID.");
if (disableSend && (workspaceId === null || !reviewEnabled))
  throw new Error(
    "SLACK_AI_DISABLE_SEND requires SLACK_AI_WORKSPACE_ID and message review.",
  );
const lifecycle = new AbortController();
process.on("SIGINT", () => lifecycle.abort());
process.on("SIGTERM", () => lifecycle.abort());
const queue = new TaskQueue(
  Number(requiredSetting("SLACK_AI_MAX_CONCURRENT_TASKS")),
);
const tasks = new Map<string, TaskEntry>();
const navigation = await readFile(
  new URL("./navigation.js", import.meta.url),
  "utf8",
);
const taskSource = (
  await readFile(new URL("./tasks-ui.js", import.meta.url), "utf8")
).replace(
  "/* @navigation@ */ null",
  () => `(() => {\n${navigation}\nreturn navigateToConversation;\n})()`,
);
const hooks: { source: string; global: string; binding: string }[] = [
  {
    source: taskSource,
    global: "__slackAiTasks",
    binding: "__slackAiTasksBridge",
  },
];
let classificationInstructions = "";
let reviewInstructions = "";
if (reviewEnabled) {
  const ignored: unknown = JSON.parse(
    requiredSetting("SLACK_REVIEW_IGNORE_CONVERSATIONS"),
  );
  if (
    !Array.isArray(ignored) ||
    !ignored.every((name) => typeof name === "string" && name.length > 0)
  )
    throw new Error("Invalid ignored conversations.");
  const prompts: unknown = JSON.parse(
    await readFile(requiredSetting("SLACK_REVIEW_PROMPTS_FILE"), "utf8"),
  );
  if (
    !isRecord(prompts) ||
    typeof prompts.classification !== "string" ||
    typeof prompts.review !== "string"
  )
    throw new Error("Invalid review prompts.");
  classificationInstructions = prompts.classification;
  reviewInstructions = prompts.review;
  const draft = await readFile(
    new URL("./review/draft.js", import.meta.url),
    "utf8",
  );
  const panel = await readFile(
    new URL("./review/panel.js", import.meta.url),
    "utf8",
  );
  const hook = (
    await readFile(new URL("./review/hook.js", import.meta.url), "utf8")
  )
    .replace(
      "/* @navigation@ */ null",
      () => `(() => {\n${navigation}\nreturn navigateToConversation;\n})()`,
    )
    .replace(
      "/* @draft@ */ null",
      () => `(() => {\n${draft}\nreturn createDraftTools();\n})()`,
    )
    .replace(
      "/* @panel@ */ null",
      () => `(() => {\n${panel}\nreturn createReviewPanel;\n})()`,
    )
    .replace("/* @ignoreConversations@ */ []", () => JSON.stringify(ignored));
  hooks.push({
    source: hook,
    global: "__slackMessageReview",
    binding: "__slackReviewBridge",
  });
  await mkdir(requiredSetting("SLACK_REVIEW_STATE_DIRECTORY"), {
    recursive: true,
    mode: 0o700,
  });
}
let prompt = "";
let summaries: SummaryStore | undefined;
if (summaryEnabled) {
  prompt = await readFile(
    requiredSetting("SLACK_THREAD_SUMMARY_PROMPT_FILE"),
    "utf8",
  );
  if (!prompt.trim()) throw new Error("The summary prompt is empty.");
  const timeline = await readFile(
    new URL("./summary/timeline.js", import.meta.url),
    "utf8",
  );
  const hook = (
    await readFile(new URL("./summary/hook.js", import.meta.url), "utf8")
  ).replace(
    "/* @timeline@ */ null",
    () => `(() => {\n${timeline}\nreturn createTimeline;\n})()`,
  );
  hooks.push({
    source: hook,
    global: "__slackThreadSummary",
    binding: "__slackThreadSummaryBridge",
  });
  await mkdir(requiredSetting("SLACK_THREAD_SUMMARY_STATE_DIRECTORY"), {
    recursive: true,
    mode: 0o700,
  });
  summaries = new SummaryStore(
    requiredSetting("SLACK_THREAD_SUMMARY_STATE_DIRECTORY"),
  );
}
const stateDirectory = requiredSetting("SLACK_AI_STATE_DIRECTORY");
await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
configureServiceLog(`${stateDirectory}/service.log`);
const taskStore = new TaskStore(stateDirectory);
const reviewSnapshots = new Map<string, StoredReviewSnapshot>();
for (const saved of await taskStore.load()) {
  if (saved.status === "sending") saved.status = "send-unknown";
  else if (["running", "queued"].includes(saved.status))
    saved.status = "interrupted";
  else if (saved.status === "ready-to-send") saved.status = "needs-approval";
  reviewSnapshots.set(saved.id, saved);
}
const listeners = new Set<SummaryListener>();

async function connect(target: DebugTarget): Promise<void> {
  const owner = randomUUID();
  const installedHooks = hooks.map((hook) => ({
    ...hook,
    source: hook.source
      .replace("@controllerId@", owner)
      .replaceAll("/* @workspaceId@ */ null", JSON.stringify(workspaceId))
      .replaceAll("/* @disableSend@ */ false", JSON.stringify(disableSend)),
  }));
  const websocket = new WebSocket(target.webSocketDebuggerUrl);
  const requests = new Map<number, PendingCall>();
  const jobs = new Set<Promise<void>>();
  let sequence = 0;
  const active = new Map<string, SummarySession>();
  const threadJobs = new Map<string, SummarySession>();
  const subscriptions = new Map<number, Set<string>>();
  const contextWorkspaces = new Map<number, string>();
  let stopping = false;
  const installedScripts: string[] = [];
  const bindings: string[] = [];
  const reviewSessions = new Map<string, ReviewSession>();
  const taskContexts = new Set<number>();
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  let heartbeatBusy = false;
  let finish: () => void;
  const ended = new Promise<void>((resolve) => {
    finish = resolve;
  });
  const abort = () => {
    cancelAll("Service stopped.");
    finish();
  };
  lifecycle.signal.addEventListener("abort", abort, { once: true });

  function call(
    method: string,
    params: Record<string, unknown> = {},
  ): Promise<Record<string, unknown>> {
    const id = ++sequence;
    return new Promise<Record<string, unknown>>((resolve, reject) => {
      const timeout = setTimeout(() => {
        requests.delete(id);
        reject(new Error(`CDP timeout: ${method}`));
      }, 3000);
      requests.set(id, { resolve, reject, timeout });
      try {
        websocket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timeout);
        requests.delete(id);
        reject(error);
      }
    });
  }

  async function evaluate(
    expression: string,
    contextId?: number,
  ): Promise<unknown> {
    const result = await call("Runtime.evaluate", {
      expression,
      returnByValue: true,
      ...(contextId === undefined ? {} : { contextId }),
    });
    return evaluationValue(result);
  }

  function workspaceGuard(expected: string): string {
    return `window.__slackAiTasks?.owner === ${JSON.stringify(owner)} && location.hostname === "app.slack.com" && location.pathname.match(/^\\/client\\/(T[A-Z0-9]+)(?:\\/|$)/)?.[1] === ${JSON.stringify(expected)}`;
  }

  async function evaluateInWorkspace(
    expression: string,
    contextId: number,
    expected: string,
  ): Promise<unknown> {
    return evaluate(
      `(() => { if (${workspaceGuard(expected)}) { ${expression}; return true; } return false; })()`,
      contextId,
    );
  }

  async function acceptsWorkspace(
    contextId: number,
    expected: unknown,
  ): Promise<boolean> {
    if (
      typeof expected !== "string" ||
      !/^T[A-Z0-9]+$/.test(expected) ||
      (workspaceId !== null && expected !== workspaceId)
    )
      return false;
    return (await evaluate(workspaceGuard(expected), contextId)) === true;
  }

  function cancelAll(reason: string): void {
    for (const session of active.values())
      session.controller.abort(new Error(reason));
    active.clear();
    threadJobs.clear();
    for (const session of reviewSessions.values())
      session.controller?.abort(new Error(reason));
    reviewSessions.clear();
    for (const entry of tasks.values()) {
      if (entry.targetId !== target.id) continue;
      if (["queued", "running"].includes(entry.view.status)) {
        entry.view.status = "interrupted";
        entry.view.error = reason;
      } else if (entry.view.status === "sending") {
        entry.view.status = "send-unknown";
        entry.view.error = "Check the conversation before sending again.";
      } else if (entry.view.status === "ready-to-send") {
        entry.view.status = "needs-approval";
      }
      const saved = reviewSnapshots.get(entry.view.id);
      if (saved) saved.status = entry.view.status;
      entry.view.updatedAt = Date.now();
      entry.targetId = "";
      entry.contextId = 0;
    }
    void persistReviews().catch((error) => console.error(errorMessage(error)));
  }

  async function publishTasks(): Promise<void> {
    await Promise.allSettled(
      [...taskContexts].map(async (contextId) => {
        const activeWorkspace = await evaluate(
          'location.hostname === "app.slack.com" ? location.pathname.match(/^\\/client\\/(T[A-Z0-9]+)(?:\\/|$)/)?.[1] : null',
          contextId,
        );
        if (
          typeof activeWorkspace !== "string" ||
          (workspaceId !== null && workspaceId !== activeWorkspace)
        )
          return;
        const views = [...tasks.values()]
          .filter(
            (entry) =>
              entry.targetId === target.id &&
              entry.view.workspaceId === activeWorkspace,
          )
          .map((entry) => entry.view);
        return evaluateInWorkspace(
          `window.__slackAiTasks?.receive(${JSON.stringify(views)}); for (const task of ${JSON.stringify(views.filter((view) => view.kind === "review").map((view) => ({ id: view.id, tools: view.tools })))}) window.__slackMessageReview?.activity(task.id, task.tools)`,
          contextId,
          activeWorkspace,
        );
      }),
    );
  }

  function persistReviews(): Promise<void> {
    return taskStore.save([...reviewSnapshots.values()]);
  }

  async function restoreReviews(
    contextId: number,
    expected: string,
  ): Promise<void> {
    const snapshots = [...reviewSnapshots.values()].filter(
      (saved) => saved.workspaceId === expected,
    );
    for (const saved of snapshots) {
      const existing = tasks.get(saved.id);
      if (existing && existing.targetId && existing.targetId !== target.id)
        continue;
      const labels = new Map(
        saved.projection.elements.map(({ token, label }) => [token, label]),
      );
      const display = (text: string) =>
        text.replace(
          /⟦SLACK_ELEMENT_[^⟧]*⟧/g,
          (token) => labels.get(token) ?? token,
        );
      tasks.set(saved.id, {
        targetId: target.id,
        contextId,
        view: existing?.view ?? {
          id: saved.id,
          workspaceId: expected,
          destination: saved.destination,
          kind: "review",
          status: saved.status,
          title: display(saved.previewOriginal).slice(0, 100),
          original: display(saved.previewOriginal),
          conversation: saved.context?.conversation ?? "",
          url: saved.location,
          createdAt: saved.startedAt,
          updatedAt: Date.now(),
          tools: [],
          suggestion:
            saved.result && "suggestion" in saved.result
              ? display(saved.result.suggestion)
              : undefined,
          assessment:
            saved.result && "assessment" in saved.result
              ? saved.result.assessment
              : undefined,
          coreQuestion:
            saved.result && "coreQuestion" in saved.result
              ? saved.result.coreQuestion
              : undefined,
          error:
            saved.status === "send-unknown"
              ? "Check the conversation before sending again."
              : undefined,
        },
      });
    }
    await evaluateInWorkspace(
      `window.__slackMessageReview?.receiveSnapshots(${JSON.stringify(snapshots.filter((saved) => tasks.get(saved.id)?.targetId === target.id))})`,
      contextId,
      expected,
    );
  }

  function updateTask(id: string, patch: Partial<TaskView>): void {
    const entry = tasks.get(id);
    if (!entry || entry.targetId !== target.id) return;
    Object.assign(entry.view, patch, { updatedAt: Date.now() });
    const saved = reviewSnapshots.get(id);
    if (saved) {
      saved.status = entry.view.status;
      void persistReviews().catch((error) => {
        entry.view.error = `Draft not saved: ${errorMessage(error)}. Keep the draft and retry.`;
        void publishTasks();
      });
    }
    void publishTasks();
  }

  function addTask(contextId: number, view: TaskView): void {
    tasks.set(view.id, { targetId: target.id, contextId, view });
    taskContexts.add(contextId);
    void publishTasks();
  }

  function toolEvent(id: string, event: ToolEvent): void {
    const entry = tasks.get(id);
    if (!entry || entry.targetId !== target.id) return;
    const index = entry.view.tools.findIndex((tool) => tool.id === event.id);
    if (index < 0) entry.view.tools.push(event);
    else entry.view.tools[index] = event;
    updateTask(id, {});
  }

  async function handleReview(
    params: BindingEvent,
    requestWorkspace: string,
  ): Promise<void> {
    const request = parseReviewRequest(JSON.parse(params.payload));
    if (request.kind === "attached") {
      taskContexts.add(params.executionContextId);
      await restoreReviews(params.executionContextId, requestWorkspace);
      await publishTasks();
      return;
    }
    const sourceLocation =
      request.kind === "captured"
        ? request.location
        : request.kind === "classify" || request.kind === "review"
          ? request.context.location
          : undefined;
    if (sourceLocation !== undefined) {
      const sourceUrl = new URL(sourceLocation);
      if (
        sourceUrl.hostname !== "app.slack.com" ||
        sourceUrl.pathname.match(/^\/client\/(T[A-Z0-9]+)(?:\/|$)/)?.[1] !==
          requestWorkspace
      )
        return;
    }
    const existing = tasks.get(request.id);
    if (
      existing &&
      (existing.targetId !== target.id ||
        existing.contextId !== params.executionContextId ||
        existing.view.workspaceId !== requestWorkspace)
    )
      return;
    if (request.kind === "snapshot") {
      const saved = request.snapshot;
      const previous = reviewSnapshots.get(saved.id);
      if (previous && saved.turn < previous.turn) return;
      if (previous && saved.turn > previous.turn) {
        reviewSessions
          .get(saved.id)
          ?.controller?.abort(new Error("Draft changed."));
        reviewSessions.delete(saved.id);
      }
      reviewSnapshots.set(saved.id, saved);
      if (existing) updateTask(saved.id, { status: saved.status });
      let error: string | undefined;
      try {
        await persistReviews();
      } catch (failure) {
        error = `Draft not saved: ${errorMessage(failure)}. Keep the draft and retry.`;
        if (existing) existing.view.error = error;
      }
      await evaluateInWorkspace(
        `window.__slackMessageReview?.receiveSaved(${JSON.stringify(saved.id)}, ${JSON.stringify(saved.turn)}, ${JSON.stringify(error)})`,
        params.executionContextId,
        requestWorkspace,
      );
      await publishTasks();
      return;
    }
    if (request.kind === "captured") {
      if (!tasks.has(request.id))
        addTask(params.executionContextId, {
          id: request.id,
          workspaceId: requestWorkspace,
          kind: "review",
          destination: request.destination,
          status: "running",
          title: request.original.slice(0, 100),
          original: request.original,
          url: request.location,
          conversation: "",
          createdAt: Date.now(),
          updatedAt: Date.now(),
          tools: [],
          progress: "Collecting conversation context",
        });
      else
        updateTask(request.id, {
          original: request.original,
          title: request.original.slice(0, 100),
          destination: request.destination,
          url: request.location,
          suggestion: undefined,
          assessment: undefined,
          coreQuestion: undefined,
          error: undefined,
        });
      return;
    }
    if (request.kind === "settled") {
      const entry = tasks.get(request.id);
      if (
        entry?.targetId !== target.id ||
        entry.contextId !== params.executionContextId
      )
        return;
      if (disableSend && request.state === "handed-to-slack") {
        updateTask(request.id, {
          status: "conflict",
          error: "Sending is disabled in this development workspace.",
        });
        return;
      }
      if (request.state === "stale") {
        reviewSessions
          .get(request.id)
          ?.controller?.abort(new Error("Draft changed."));
        reviewSessions.delete(request.id);
      }
      updateTask(request.id, { status: request.state, error: request.error });
      if (request.state === "handed-to-slack")
        reviewSessions.delete(request.id);
      return;
    }
    if (request.kind === "cancel") {
      const session = reviewSessions.get(request.id);
      const entry = tasks.get(request.id);
      if (
        entry?.targetId !== target.id ||
        entry.contextId !== params.executionContextId
      )
        return;
      session?.controller?.abort(new Error(request.reason));
      reviewSessions.delete(request.id);
      updateTask(request.id, { status: "cancelled", error: request.reason });
      return;
    }
    let session = reviewSessions.get(request.id);
    if (request.kind === "classify" || request.kind === "review") {
      if (
        session &&
        (session.contextId !== params.executionContextId || session.controller)
      )
        return;
      if (!session) {
        const captured = existing?.view;
        if (!captured || captured.kind !== "review") return;
        session = {
          id: request.id,
          original: request.original,
          context: request.context,
          protectedElements: request.protectedElements,
          history: [],
          contextId: params.executionContextId,
        };
        reviewSessions.set(request.id, session);
        const original = captured.original ?? request.original;
        addTask(params.executionContextId, {
          id: request.id,
          kind: "review",
          workspaceId: requestWorkspace,
          destination: captured.destination,
          status: "queued",
          title: original.slice(0, 100),
          original,
          conversation: request.context.conversation,
          url: request.context.location,
          createdAt: captured.createdAt,
          updatedAt: Date.now(),
          tools: [],
        });
      }
      if (request.kind === "review") {
        session.original = request.original;
        session.context = request.context;
        session.protectedElements = request.protectedElements;
      }
    }
    if (
      !session ||
      session.contextId !== params.executionContextId ||
      session.controller
    )
      return;
    const savedTurn = reviewSnapshots.get(request.id)?.turn;
    if (savedTurn !== undefined && request.turn < savedTurn) return;
    const savedRequest = reviewSnapshots.get(request.id);
    if (savedRequest) savedRequest.turn = request.turn;
    const current = session;
    current.response = undefined;
    const controller = new AbortController();
    current.controller = controller;
    updateTask(request.id, {
      status: "queued",
      error: undefined,
      progress: undefined,
    });
    let result: ReviewResult | ClassificationResult;
    try {
      result = await queue.run(controller.signal, async () => {
        updateTask(request.id, { status: "running" });
        if (request.kind === "classify")
          return classify(
            { message: current.original, context: current.context },
            controller.signal,
            classificationInstructions,
          );
        const input = {
          original: current.original,
          context: current.context,
          protectedElements: current.protectedElements,
          suggestion:
            request.kind === "ask" ? request.suggestion : current.original,
          conversation: current.history,
          revisionRequest: request.kind === "ask" ? request.instruction : "",
        };
        const answer = await review(
          input,
          controller.signal,
          reviewInstructions,
          (event) => toolEvent(request.id, event),
        );
        current.history.push(
          {
            role: "user",
            instruction: input.revisionRequest,
            suggestion: input.suggestion,
          },
          { role: "assistant", ...answer },
        );
        return answer;
      });
    } catch (error) {
      if (controller.signal.aborted) return;
      result = { error: errorMessage(error) };
    } finally {
      current.controller = undefined;
    }
    if (reviewSessions.get(request.id) !== current || controller.signal.aborted)
      return;
    const labels = new Map(
      current.protectedElements.map(({ token, label }) => [token, label]),
    );
    const display = (text: string) =>
      text.replace(
        /⟦SLACK_ELEMENT_[^⟧]*⟧/g,
        (token) => labels.get(token) ?? token,
      );
    const savedResult = reviewSnapshots.get(request.id);
    if (savedResult && "suggestion" in result) savedResult.result = result;
    updateTask(
      request.id,
      "error" in result
        ? { status: "failed", error: result.error }
        : {
            status: "needs-approval",
            suggestion: display(
              "suggestion" in result ? result.suggestion : current.original,
            ),
            assessment: "assessment" in result ? result.assessment : undefined,
            coreQuestion:
              "coreQuestion" in result ? result.coreQuestion : undefined,
          },
    );
    const receiver =
      request.kind === "classify" ? "receiveClassification" : "receive";
    current.response = { receiver, turn: request.turn, result };
    const delivered = await evaluateInWorkspace(
      `window.__slackMessageReview?.${receiver}(${JSON.stringify(request.id)}, ${JSON.stringify(request.turn)}, ${JSON.stringify(result)})`,
      current.contextId,
      requestWorkspace,
    );
    if (delivered === true) current.response = undefined;
  }

  async function handleTasks(
    params: BindingEvent,
    requestWorkspace: string,
  ): Promise<void> {
    const request: unknown = JSON.parse(params.payload);
    if (!isRecord(request)) return;
    taskContexts.add(params.executionContextId);
    if (request.kind === "list") {
      await restoreReviews(params.executionContextId, requestWorkspace);
      await publishTasks();
      for (const session of reviewSessions.values()) {
        const entry = tasks.get(session.id);
        const response = session.response;
        if (
          !response ||
          session.contextId !== params.executionContextId ||
          entry?.view.workspaceId !== requestWorkspace
        )
          continue;
        const delivered = await evaluateInWorkspace(
          `window.__slackMessageReview?.${response.receiver}(${JSON.stringify(session.id)}, ${JSON.stringify(response.turn)}, ${JSON.stringify(response.result)})`,
          session.contextId,
          requestWorkspace,
        );
        if (delivered === true && session.response === response)
          session.response = undefined;
      }
      return;
    }
    if (
      request.kind === "resolve-send" &&
      typeof request.id === "string" &&
      typeof request.sent === "boolean"
    ) {
      const entry = tasks.get(request.id);
      const saved = reviewSnapshots.get(request.id);
      if (
        !entry ||
        !saved ||
        entry.targetId !== target.id ||
        entry.view.workspaceId !== requestWorkspace ||
        entry.view.status !== "send-unknown"
      )
        return;
      updateTask(request.id, {
        status: request.sent ? "handed-to-slack" : "stale",
        error: undefined,
      });
      await restoreReviews(params.executionContextId, requestWorkspace);
      return;
    }
    if (request.kind !== "cancel" || typeof request.id !== "string") return;
    const entry = tasks.get(request.id);
    if (
      !entry ||
      entry.targetId !== target.id ||
      entry.contextId !== params.executionContextId ||
      entry.view.workspaceId !== requestWorkspace
    )
      return;
    if (
      ![
        "queued",
        "running",
        "needs-approval",
        "conflict",
        "failed",
        "stale",
        "ready-to-send",
        "interrupted",
      ].includes(entry.view.status)
    )
      return;
    reviewSessions
      .get(request.id)
      ?.controller?.abort(new Error("Task cancelled."));
    reviewSessions.delete(request.id);
    active.get(request.id)?.controller.abort(new Error("Task cancelled."));
    updateTask(request.id, { status: "cancelled", error: undefined });
    await evaluateInWorkspace(
      `window.__slackMessageReview?.cancel(${JSON.stringify(request.id)})`,
      params.executionContextId,
      requestWorkspace,
    );
  }

  async function publish(
    thread: ThreadIdentity,
    card?: StoredCard,
    deletedId?: string,
    error?: string,
    jobId?: string,
  ): Promise<void> {
    const key = threadKey(thread);
    await Promise.allSettled(
      [...subscriptions]
        .filter(([, keys]) => keys.has(key))
        .map(([contextId]) =>
          evaluateInWorkspace(
            `window.__slackThreadSummary?.receiveCards(${JSON.stringify(thread)}, ${JSON.stringify(card ? [card] : [])}, ${JSON.stringify(deletedId ? [deletedId] : [])}, ${JSON.stringify(error)}, ${JSON.stringify(jobId)})`,
            contextId,
            thread.teamId,
          ),
        ),
    );
  }
  listeners.add(publish);

  async function handleBinding(params: BindingEvent): Promise<void> {
    if (stopping) return;
    const envelope: unknown = JSON.parse(params.payload);
    if (
      !isRecord(envelope) ||
      typeof envelope.workspaceId !== "string" ||
      !(await acceptsWorkspace(params.executionContextId, envelope.workspaceId))
    )
      return;
    const requestWorkspace = envelope.workspaceId;
    if (contextWorkspaces.get(params.executionContextId) !== requestWorkspace) {
      subscriptions.delete(params.executionContextId);
      contextWorkspaces.set(params.executionContextId, requestWorkspace);
    }
    if (params.name === "__slackAiTasksBridge")
      return handleTasks(params, requestWorkspace);
    if (params.name === "__slackReviewBridge" && reviewEnabled)
      return handleReview(params, requestWorkspace);
    if (params.name !== "__slackThreadSummaryBridge" || !summaries) return;
    const request = parseRequest(JSON.parse(params.payload));
    if (typeof request.id !== "string") return;
    if ("thread" in request && request.thread.teamId !== requestWorkspace)
      return;
    const existing = tasks.get(request.id);
    if (
      existing &&
      (existing.targetId !== target.id ||
        existing.contextId !== params.executionContextId ||
        existing.view.workspaceId !== requestWorkspace)
    )
      return;
    if (request.kind === "cancel") {
      const session = active.get(request.id);
      if (session?.contextId === params.executionContextId) {
        session.controller.abort(new Error("Summary cancelled."));
        active.delete(request.id);
        if (threadJobs.get(session.key) === session)
          threadJobs.delete(session.key);
      }
      return;
    }
    if (active.has(request.id)) return;

    const session: SummarySession = {
      id: request.id,
      controller: new AbortController(),
      contextId: params.executionContextId,
      key: threadKey(request.thread),
      progress: "Summarizing…",
    };
    active.set(request.id, session);
    async function deliver(result: SummaryResult): Promise<void> {
      if (
        active.get(request.id) !== session ||
        session.controller.signal.aborted
      )
        return;
      await evaluateInWorkspace(
        `window.__slackThreadSummary?.receive(${JSON.stringify(request.id)}, ${JSON.stringify(result)})`,
        session.contextId,
        requestWorkspace,
      ).catch((error) =>
        console.error(`Summary UI update unavailable: ${errorMessage(error)}`),
      );
    }
    try {
      const key = threadKey(request.thread);
      const subscribed =
        subscriptions.get(session.contextId) ?? new Set<string>();
      subscribed.add(key);
      subscriptions.set(session.contextId, subscribed);
      if (request.kind === "delete") {
        await summaries.delete(request.thread, request.cardId);
        await Promise.allSettled(
          [...listeners].map((listener) =>
            listener(request.thread, undefined, request.cardId),
          ),
        );
        await deliver({ deletedIds: [request.cardId] });
        return;
      }
      if (request.kind === "load") {
        const cards = await summaries.list(request.thread);
        const job = threadJobs.get(key);
        await deliver({
          cards,
          job: job && { id: job.id, progress: job.progress },
        });
        return;
      }
      if (request.kind === "summarize") {
        const job = threadJobs.get(key);
        if (job) {
          await deliver({ job: { id: job.id, progress: job.progress } });
          return;
        }
        session.key = key;
        session.progress = "Queued";
        threadJobs.set(key, session);
        addTask(session.contextId, {
          id: session.id,
          workspaceId: requestWorkspace,
          kind: "summary",
          destination: {
            workspaceId: request.thread.teamId,
            channelId: request.thread.channelId,
            threadTs: request.thread.threadTs,
          },
          status: "queued",
          title: `Summarize ${request.location.conversation}`,
          conversation: request.location.conversation,
          url: `https://app.slack.com/client/${request.thread.teamId}/${request.thread.channelId}/thread/${request.thread.channelId}-${request.thread.threadTs}`,
          createdAt: Date.now(),
          updatedAt: Date.now(),
          tools: [],
        });
      }
      if (
        request.kind === "summarize" &&
        (typeof request.throughTs !== "string" ||
          !/^\d+\.\d+$/.test(request.throughTs) ||
          request.throughTs < request.thread.threadTs)
      )
        throw new Error("The summary boundary is unavailable.");

      let card: SummaryCard;
      if (request.kind === "save") {
        card = summaries.pending(request.thread, request.cardId);
      } else {
        const result = await queue.run(session.controller.signal, async () => {
          updateTask(session.id, { status: "running" });
          return summarize(
            request.messages,
            request.location,
            session.controller.signal,
            prompt,
            (progress) => {
              session.progress = progress;
              updateTask(session.id, { progress });
              return deliver({ progress });
            },
            (event) => toolEvent(session.id, event),
          );
        });
        session.controller.signal.throwIfAborted();
        card = {
          id: randomUUID(),
          throughTs: request.throughTs,
          generatedAt: new Date().toISOString(),
          count: request.messages.length,
          summary: result,
        };
      }
      let saved = true;
      let saveError: string | undefined;
      try {
        await summaries.save(request.thread, card);
      } catch (error) {
        saved = false;
        saveError = `Summary not saved: ${errorMessage(error)}. Use Retry save; no new AI call is needed.`;
      }
      const entry = { ...card, saved };
      const taskId =
        request.kind === "save"
          ? [...tasks.values()].find(
              (task) =>
                task.targetId === target.id &&
                task.view.summary?.id === card.id,
            )?.view.id
          : session.id;
      if (taskId)
        updateTask(taskId, {
          status: "completed",
          summary: entry,
          progress: undefined,
          error: saveError,
        });
      if (threadJobs.get(session.key) === session)
        threadJobs.delete(session.key);
      await Promise.allSettled(
        [...listeners].map((listener) =>
          listener(
            request.thread,
            entry,
            undefined,
            undefined,
            request.kind === "summarize" ? session.id : undefined,
          ),
        ),
      );
      await deliver({ cards: [entry], saveError });
    } catch (error) {
      if (request.kind === "summarize")
        updateTask(session.id, {
          status:
            tasks.get(session.id)?.view.status === "interrupted"
              ? "interrupted"
              : session.controller.signal.aborted
                ? "cancelled"
                : "failed",
          error: errorMessage(error),
        });
      if (request.kind === "summarize")
        await Promise.allSettled(
          [...listeners].map((listener) =>
            listener(
              request.thread,
              undefined,
              undefined,
              session.controller.signal.aborted
                ? "Summary cancelled."
                : errorMessage(error),
              session.id,
            ),
          ),
        );
      if (!session.controller.signal.aborted) {
        if (threadJobs.get(session.key) === session)
          threadJobs.delete(session.key);
        console.error(errorMessage(error));
        await deliver({ error: errorMessage(error) });
      }
    } finally {
      session.controller.abort();
      if (active.get(request.id) === session) active.delete(request.id);
      if (threadJobs.get(session.key) === session)
        threadJobs.delete(session.key);
    }
  }

  websocket.addEventListener("message", (event) => {
    let message: Record<string, unknown>;
    try {
      message = parseMessage(event.data);
    } catch (error) {
      console.error(errorMessage(error));
      return;
    }
    if (typeof message.id === "number") {
      const pending = requests.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timeout);
      requests.delete(message.id);
      if (isRecord(message.error))
        pending.reject(new Error(String(message.error.message)));
      else if (isRecord(message.result)) pending.resolve(message.result);
      else pending.reject(new Error("Invalid Slack debugger response."));
      return;
    }
    if (message.method === "Runtime.bindingCalled") {
      const job = Promise.resolve()
        .then(() => handleBinding(parseBinding(message.params)))
        .catch((error: unknown) => console.error(errorMessage(error)));
      jobs.add(job);
      void job.finally(() => jobs.delete(job));
    }
    if (message.method === "Runtime.executionContextsCleared") {
      subscriptions.clear();
      contextWorkspaces.clear();
      taskContexts.clear();
      cancelAll("Slack page reloaded.");
    } else if (message.method === "Runtime.executionContextDestroyed") {
      const contextId = isRecord(message.params)
        ? message.params.executionContextId
        : undefined;
      if (typeof contextId !== "number") return;
      subscriptions.delete(contextId);
      contextWorkspaces.delete(contextId);
      taskContexts.delete(contextId);
      for (const [id, session] of reviewSessions) {
        if (session.contextId !== contextId) continue;
        session.controller?.abort(new Error("Slack page reloaded."));
        reviewSessions.delete(id);
      }
      for (const entry of tasks.values()) {
        if (entry.targetId !== target.id || entry.contextId !== contextId)
          continue;
        if (["queued", "running"].includes(entry.view.status))
          updateTask(entry.view.id, {
            status: "interrupted",
            error: "Slack page reloaded.",
          });
        else if (entry.view.status === "sending")
          updateTask(entry.view.id, {
            status: "send-unknown",
            error: "Check the conversation before sending again.",
          });
        else if (entry.view.status === "ready-to-send")
          updateTask(entry.view.id, { status: "needs-approval" });
        entry.contextId = 0;
      }
      for (const [id, session] of active) {
        if (session.contextId === contextId) {
          session.controller.abort(new Error("Slack page reloaded."));
          active.delete(id);
          if (threadJobs.get(session.key) === session)
            threadJobs.delete(session.key);
        }
      }
    }
  });
  websocket.addEventListener("close", () => {
    cancelAll("Slack connection closed.");
    for (const pending of requests.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("Slack connection closed."));
    }
    requests.clear();
    finish();
  });

  try {
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("Slack CDP connection timed out.")),
        5000,
      );
      websocket.addEventListener(
        "open",
        () => {
          clearTimeout(timeout);
          resolve();
        },
        { once: true },
      );
      websocket.addEventListener(
        "error",
        () => {
          clearTimeout(timeout);
          reject(new Error("Slack CDP connection failed."));
        },
        { once: true },
      );
      websocket.addEventListener(
        "close",
        () => {
          clearTimeout(timeout);
          reject(new Error("Slack CDP connection closed."));
        },
        { once: true },
      );
    });
    lifecycle.signal.throwIfAborted();
    await call("Runtime.enable");
    await call("Page.enable");
    for (const hook of installedHooks) {
      if (await evaluate(`Boolean(window.${hook.global})`))
        throw new Error("A Slack AI controller is already attached.");
      await call("Runtime.addBinding", { name: hook.binding });
      bindings.push(hook.binding);
      const script = await call("Page.addScriptToEvaluateOnNewDocument", {
        source: hook.source,
      });
      if (typeof script.identifier !== "string")
        throw new Error("Invalid Slack script identifier.");
      installedScripts.push(script.identifier);
      await evaluate(hook.source);
    }
    console.error("Slack AI integration ready.");
    heartbeat = setInterval(async () => {
      if (heartbeatBusy || stopping) return;
      heartbeatBusy = true;
      try {
        for (const hook of installedHooks) {
          const result = await evaluate(
            `window.${hook.global}?.pulse(${JSON.stringify(owner)}) ?? null`,
          );
          if (result === null) await evaluate(hook.source);
          else if (!result)
            throw new Error("The Slack hook belongs to another controller.");
        }
      } catch (error) {
        console.error(errorMessage(error));
        finish();
      } finally {
        heartbeatBusy = false;
      }
    }, 5000);
    await ended;
  } finally {
    stopping = true;
    listeners.delete(publish);
    subscriptions.clear();
    clearInterval(heartbeat);
    lifecycle.signal.removeEventListener("abort", abort);
    cancelAll("Summary connection stopped.");
    if (websocket.readyState === WebSocket.OPEN) {
      try {
        for (const identifier of installedScripts)
          await call("Page.removeScriptToEvaluateOnNewDocument", {
            identifier,
          });
        for (const hook of installedHooks)
          await evaluate(
            `if (window.${hook.global}?.owner === ${JSON.stringify(owner)}) window.${hook.global}.stop()`,
          );
        for (const name of bindings)
          await call("Runtime.removeBinding", { name });
      } catch (error) {
        console.error(
          `Hook cleanup interrupted; its lease expires automatically: ${errorMessage(error)}`,
        );
      }
    }
    websocket.close();
    await Promise.allSettled([...jobs]);
  }
}

let lastStatus: string | undefined;
const connections = new Map<string, Promise<void>>();
let connectedOnce = false;
while (!lifecycle.signal.aborted) {
  try {
    const response = await fetch(`${endpoint}/json/list`, {
      signal: AbortSignal.any([lifecycle.signal, AbortSignal.timeout(5000)]),
    });
    if (!response.ok) throw new Error(`Slack CDP returned ${response.status}.`);
    const pages = parseTargets(await response.json()).filter(
      (target) =>
        target.type === "page" &&
        target.url.startsWith("https://app.slack.com/"),
    );
    if (!pages.length) {
      if (connectedOnce && !connections.size) break;
      throw new Error("Waiting for a Slack window.");
    }
    lastStatus = undefined;
    connectedOnce = true;
    for (const page of pages) {
      if (connections.has(page.id)) continue;
      const connection = connect(page)
        .catch((error) => console.error(errorMessage(error)))
        .finally(() => connections.delete(page.id));
      connections.set(page.id, connection);
    }
  } catch (error) {
    if (lifecycle.signal.aborted) break;
    if (
      connectedOnce &&
      !connections.size &&
      isRecord(error) &&
      hasErrorCode(error.cause, "ECONNREFUSED")
    )
      break;
    const message =
      isRecord(error) && hasErrorCode(error.cause, "ECONNREFUSED")
        ? "Waiting for Slack debugging on 127.0.0.1:9222. If Slack is already running normally, quit and reopen it through this service."
        : errorMessage(error);
    if (message !== lastStatus) console.error(message);
    lastStatus = message;
  }
  await delay(5000, undefined, { signal: lifecycle.signal }).catch(() => {});
}
lifecycle.abort();
await Promise.allSettled([...connections.values()]);
await taskStore.flush();
