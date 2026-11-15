import type { ConversationDestination, TaskStatus } from "../contracts.mjs";

export interface ProtectedElement {
  token: string;
  label: string;
  href?: string | undefined;
}

export interface ReviewContext {
  location?: string;
  workspace: string;
  conversation: string;
  position: "Thread" | "New message" | "Conversation";
  threadHistory: {
    position: "Reply" | "Thread start";
    author: string;
    text: string;
  }[];
}

export interface ReviewAnswer {
  suggestion: string;
  coreQuestion?: string;
  assessment?: string;
}

export type ReviewHistory =
  | { role: "user"; instruction: string; suggestion: string }
  | ({ role: "assistant" } & ReviewAnswer);

export interface ReviewInput {
  original: string;
  suggestion: string;
  context: ReviewContext;
  protectedElements: ProtectedElement[];
  conversation: ReviewHistory[];
  revisionRequest: string;
}

export type Classification = "simple_reply" | "link_share" | "review";
export interface ClassificationAnswer {
  choice: Classification;
  model?: string | undefined;
  probability?: number | undefined;
}
export interface Failure {
  error: string;
}
export type ReviewResult = ReviewAnswer | Failure;
export type ClassificationResult = ClassificationAnswer | Failure;

export interface StoredReviewSnapshot {
  id: string;
  workspaceId: string;
  destination: ConversationDestination;
  fingerprint: string;
  original: string;
  reviewOriginal: string;
  previewOriginal: string;
  projection: {
    source: {
      insert: string | Record<string, unknown>;
      attributes: Record<string, unknown>;
    }[];
    elements: (ProtectedElement & {
      units: {
        insert: string | Record<string, unknown>;
        attributes: Record<string, unknown>;
      }[];
    })[];
    text: string;
    lines: Record<string, unknown>[];
  };
  turn: number;
  phase: "loading" | "checking" | "classification-error" | "confirm" | "review";
  status: TaskStatus;
  result?: ReviewResult | undefined;
  context?: ReviewContext | undefined;
  startedAt: number;
  location: string;
}

export function isStoredReviewSnapshot(
  value: unknown,
): value is StoredReviewSnapshot {
  const unit = (item: unknown) =>
    isRecord(item) &&
    (typeof item.insert === "string" || isRecord(item.insert)) &&
    isRecord(item.attributes);
  if (
    !isRecord(value) ||
    !isRecord(value.destination) ||
    !isRecord(value.projection)
  )
    return false;

  const projection = value.projection;
  return (
    typeof value.id === "string" &&
    typeof value.workspaceId === "string" &&
    /^T[A-Z0-9]+$/.test(value.workspaceId) &&
    value.destination.workspaceId === value.workspaceId &&
    typeof value.destination.channelId === "string" &&
    /^[CDG][A-Z0-9]+$/.test(value.destination.channelId) &&
    (value.destination.threadTs === null ||
      (typeof value.destination.threadTs === "string" &&
        /^\d+\.\d+$/.test(value.destination.threadTs))) &&
    typeof value.fingerprint === "string" &&
    typeof value.original === "string" &&
    typeof value.reviewOriginal === "string" &&
    typeof value.previewOriginal === "string" &&
    typeof value.location === "string" &&
    typeof value.startedAt === "number" &&
    typeof value.turn === "number" &&
    Number.isInteger(value.turn) &&
    [
      "loading",
      "checking",
      "classification-error",
      "confirm",
      "review",
    ].includes(String(value.phase)) &&
    [
      "queued",
      "running",
      "needs-approval",
      "completed",
      "handed-to-slack",
      "failed",
      "cancelled",
      "interrupted",
      "conflict",
      "stale",
      "ready-to-send",
      "sending",
      "send-unknown",
    ].includes(String(value.status)) &&
    typeof projection.text === "string" &&
    Array.isArray(projection.source) &&
    projection.source.every(unit) &&
    Array.isArray(projection.lines) &&
    projection.lines.every(isRecord) &&
    Array.isArray(projection.elements) &&
    projection.elements.every(
      (item: unknown) =>
        isProtectedElement(item) &&
        isRecord(item) &&
        Array.isArray(item.units) &&
        item.units.every(unit),
    ) &&
    (value.context === undefined || isContext(value.context)) &&
    (value.result === undefined ||
      (isRecord(value.result) &&
        (typeof value.result.error === "string" ||
          (typeof value.result.suggestion === "string" &&
            (value.result.coreQuestion === undefined ||
              typeof value.result.coreQuestion === "string") &&
            (value.result.assessment === undefined ||
              typeof value.result.assessment === "string")))))
  );
}

export type ReviewMessage =
  | { kind: "snapshot"; id: string; snapshot: StoredReviewSnapshot }
  | {
      kind: "captured";
      id: string;
      original: string;
      location: string;
      destination: ConversationDestination;
    }
  | {
      kind: "settled";
      id: string;
      state:
        | "handed-to-slack"
        | "conflict"
        | "failed"
        | "stale"
        | "ready-to-send"
        | "sending"
        | "send-unknown"
        | "interrupted";
      error?: string;
    }
  | { kind: "attached"; count: number }
  | { kind: "cancel"; id: string; reason: string }
  | {
      kind: "ask";
      id: string;
      turn: number;
      instruction: string;
      suggestion: string;
    }
  | {
      kind: "classify" | "review";
      id: string;
      turn: number;
      original: string;
      context: ReviewContext;
      protectedElements: ProtectedElement[];
    };

export type ReviewRequest = ReviewMessage & { workspaceId: string };

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function hasErrorCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code;
}

export function isClassification(value: unknown): value is Classification {
  return (
    value === "simple_reply" || value === "link_share" || value === "review"
  );
}

function isContext(value: unknown): value is ReviewContext {
  return (
    isRecord(value) &&
    typeof value.workspace === "string" &&
    typeof value.conversation === "string" &&
    (value.location === undefined || typeof value.location === "string") &&
    (value.position === "Thread" ||
      value.position === "New message" ||
      value.position === "Conversation") &&
    Array.isArray(value.threadHistory) &&
    value.threadHistory.every(
      (entry: unknown) =>
        isRecord(entry) &&
        (entry.position === "Reply" || entry.position === "Thread start") &&
        typeof entry.author === "string" &&
        typeof entry.text === "string",
    )
  );
}

function isProtectedElement(value: unknown): value is ProtectedElement {
  return (
    isRecord(value) &&
    typeof value.token === "string" &&
    typeof value.label === "string" &&
    (value.href === undefined || typeof value.href === "string")
  );
}

export function parseRequest(value: unknown): ReviewRequest {
  if (
    !isRecord(value) ||
    typeof value.workspaceId !== "string" ||
    !/^T[A-Z0-9]+$/.test(value.workspaceId)
  ) {
    throw new Error("The review workspace is unavailable.");
  }
  return { ...parseMessage(value), workspaceId: value.workspaceId };
}

function parseMessage(value: unknown): ReviewMessage {
  if (isRecord(value)) {
    if (value.kind === "attached" && typeof value.count === "number")
      return { kind: "attached", count: value.count };
    if (typeof value.id === "string") {
      if (
        value.kind === "snapshot" &&
        isStoredReviewSnapshot(value.snapshot) &&
        value.snapshot.id === value.id &&
        value.snapshot.workspaceId === value.workspaceId
      )
        return { kind: "snapshot", id: value.id, snapshot: value.snapshot };
      if (
        value.kind === "captured" &&
        typeof value.original === "string" &&
        typeof value.location === "string" &&
        isRecord(value.destination) &&
        value.destination.workspaceId === value.workspaceId &&
        typeof value.destination.workspaceId === "string" &&
        typeof value.destination.channelId === "string" &&
        /^[CDG][A-Z0-9]+$/.test(value.destination.channelId) &&
        (value.destination.threadTs === null ||
          (typeof value.destination.threadTs === "string" &&
            /^\d+\.\d+$/.test(value.destination.threadTs)))
      ) {
        return {
          kind: "captured",
          id: value.id,
          original: value.original,
          location: value.location,
          destination: {
            workspaceId: value.destination.workspaceId,
            channelId: value.destination.channelId,
            threadTs: value.destination.threadTs,
          },
        };
      }
      if (
        value.kind === "settled" &&
        (value.state === "handed-to-slack" ||
          value.state === "conflict" ||
          value.state === "failed" ||
          value.state === "stale" ||
          value.state === "ready-to-send" ||
          value.state === "sending" ||
          value.state === "send-unknown" ||
          value.state === "interrupted") &&
        (value.error === undefined || typeof value.error === "string")
      ) {
        return {
          kind: "settled",
          id: value.id,
          state: value.state,
          ...(typeof value.error === "string" ? { error: value.error } : {}),
        };
      }
      if (value.kind === "cancel" && typeof value.reason === "string")
        return { kind: "cancel", id: value.id, reason: value.reason };
      if (typeof value.turn === "number" && Number.isInteger(value.turn)) {
        if (
          value.kind === "ask" &&
          typeof value.instruction === "string" &&
          typeof value.suggestion === "string"
        )
          return {
            kind: "ask",
            id: value.id,
            turn: value.turn,
            instruction: value.instruction,
            suggestion: value.suggestion,
          };
        if (
          (value.kind === "classify" || value.kind === "review") &&
          typeof value.original === "string" &&
          isContext(value.context) &&
          Array.isArray(value.protectedElements) &&
          value.protectedElements.every(isProtectedElement)
        )
          return {
            kind: value.kind,
            id: value.id,
            turn: value.turn,
            original: value.original,
            context: value.context,
            protectedElements: value.protectedElements,
          };
      }
    }
  }
  throw new Error("Invalid Slack review request.");
}
