export interface ProtectedElement {
  token: string;
  label: string;
  href?: string | undefined;
}

export interface ReviewContext {
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

export type ReviewRequest =
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
  if (isRecord(value)) {
    if (value.kind === "attached" && typeof value.count === "number")
      return { kind: "attached", count: value.count };
    if (typeof value.id === "string") {
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
