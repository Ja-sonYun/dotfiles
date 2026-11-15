export interface ThreadIdentity {
  teamId: string;
  channelId: string;
  threadTs: string;
}

export interface ThreadMessage {
  ts: string;
  permalink: string;
  author: string;
  text: string;
  mentions?: Record<string, string>;
}

export interface ThreadLocation {
  workspace: string;
  conversation: string;
  position: "Thread";
}

export interface Summary {
  overview: string;
  decisions: string[];
  actions: string[];
  sources?: { ts: string; url: string }[];
  actionDetails?: {
    text: string;
    owner: string;
    due: string;
    sources: string[];
  }[];
  openQuestions?: string[];
}

export interface SummaryCard {
  id: string;
  throughTs: string;
  generatedAt: string;
  count: number;
  summary: Summary;
}

export interface StoredCard extends SummaryCard {
  saved: boolean;
}

export interface SummaryJob {
  id: string;
  progress: string;
}

export type SummaryResult =
  | {
      error: string;
      progress?: never;
      cards?: never;
      job?: never;
      deletedIds?: never;
      saveError?: never;
    }
  | {
      error?: never;
      progress?: string;
      cards?: StoredCard[];
      job?: SummaryJob | undefined;
      deletedIds?: string[];
      saveError?: string | undefined;
    };

export type SummaryOperation =
  | { kind: "cancel"; id: string; thread: ThreadIdentity }
  | { kind: "load"; id: string; thread: ThreadIdentity }
  | {
      kind: "save";
      id: string;
      thread: ThreadIdentity;
      cardId: string;
    }
  | { kind: "delete"; id: string; thread: ThreadIdentity; cardId: string }
  | {
      kind: "summarize";
      id: string;
      thread: ThreadIdentity;
      messages: ThreadMessage[];
      location: ThreadLocation;
      throughTs: string;
    };

export type SummaryRequest = SummaryOperation & { workspaceId: string };

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function hasErrorCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code;
}

export function isThread(value: unknown): value is ThreadIdentity {
  return (
    isRecord(value) &&
    typeof value.teamId === "string" &&
    value.teamId.length > 0 &&
    typeof value.channelId === "string" &&
    value.channelId.length > 0 &&
    typeof value.threadTs === "string" &&
    value.threadTs.length > 0
  );
}

export function isSummary(value: unknown): value is Summary {
  return (
    isRecord(value) &&
    typeof value.overview === "string" &&
    Array.isArray(value.decisions) &&
    value.decisions.every((item: unknown) => typeof item === "string") &&
    Array.isArray(value.actions) &&
    value.actions.every((item: unknown) => typeof item === "string") &&
    (value.sources === undefined ||
      (Array.isArray(value.sources) &&
        value.sources.every(
          (item: unknown) =>
            isRecord(item) &&
            typeof item.ts === "string" &&
            /^\d+\.\d+$/.test(item.ts) &&
            typeof item.url === "string" &&
            item.url.startsWith("https://app.slack.com/client/"),
        ))) &&
    (value.actionDetails === undefined ||
      (Array.isArray(value.actionDetails) &&
        value.actionDetails.every(
          (item: unknown) =>
            isRecord(item) &&
            typeof item.text === "string" &&
            typeof item.owner === "string" &&
            typeof item.due === "string" &&
            Array.isArray(item.sources) &&
            item.sources.every((source: unknown) => typeof source === "string"),
        ))) &&
    (value.openQuestions === undefined ||
      (Array.isArray(value.openQuestions) &&
        value.openQuestions.every((item: unknown) => typeof item === "string")))
  );
}

export function isCard(value: unknown): value is SummaryCard {
  return (
    isRecord(value) &&
    typeof value.id === "string" &&
    /^[a-f0-9-]{36}$/.test(value.id) &&
    typeof value.throughTs === "string" &&
    /^\d+\.\d+$/.test(value.throughTs) &&
    typeof value.generatedAt === "string" &&
    Number.isFinite(Date.parse(value.generatedAt)) &&
    typeof value.count === "number" &&
    Number.isInteger(value.count) &&
    value.count > 0 &&
    isSummary(value.summary)
  );
}

function isMessage(value: unknown): value is ThreadMessage {
  return (
    isRecord(value) &&
    typeof value.ts === "string" &&
    /^\d+\.\d+$/.test(value.ts) &&
    typeof value.permalink === "string" &&
    value.permalink.startsWith("https://app.slack.com/client/") &&
    typeof value.author === "string" &&
    typeof value.text === "string" &&
    (value.mentions === undefined ||
      (isRecord(value.mentions) &&
        Object.values(value.mentions).every(
          (name) => typeof name === "string",
        )))
  );
}

function isLocation(value: unknown): value is ThreadLocation {
  return (
    isRecord(value) &&
    typeof value.workspace === "string" &&
    typeof value.conversation === "string" &&
    value.position === "Thread"
  );
}

export function parseRequest(value: unknown): SummaryRequest {
  if (
    isRecord(value) &&
    typeof value.id === "string" &&
    typeof value.workspaceId === "string" &&
    /^T[A-Z0-9]+$/.test(value.workspaceId)
  ) {
    const workspaceId = value.workspaceId;
    if (isThread(value.thread) && value.thread.teamId === workspaceId) {
      if (value.kind === "cancel")
        return {
          kind: "cancel",
          id: value.id,
          thread: value.thread,
          workspaceId,
        };
      if (value.kind === "load")
        return {
          kind: "load",
          id: value.id,
          thread: value.thread,
          workspaceId,
        };
      if (
        (value.kind === "save" || value.kind === "delete") &&
        typeof value.cardId === "string"
      )
        return {
          kind: value.kind,
          id: value.id,
          thread: value.thread,
          cardId: value.cardId,
          workspaceId,
        };
      if (
        value.kind === "summarize" &&
        Array.isArray(value.messages) &&
        value.messages.length > 0 &&
        value.messages.every(isMessage) &&
        isLocation(value.location) &&
        typeof value.throughTs === "string"
      )
        return {
          kind: "summarize",
          id: value.id,
          thread: value.thread,
          messages: value.messages,
          location: value.location,
          throughTs: value.throughTs,
          workspaceId,
        };
    }
  }
  throw new Error("Invalid Slack summary request.");
}
