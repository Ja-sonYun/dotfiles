import type { StoredCard } from "./summary/contracts.mjs";

export interface ToolEvent {
  id: string;
  type: string;
  server?: string | undefined;
  tool?: string | undefined;
  status: string;
  elapsedMs?: number | null | undefined;
}

export type TaskStatus =
  | "queued"
  | "running"
  | "needs-approval"
  | "completed"
  | "handed-to-slack"
  | "failed"
  | "cancelled"
  | "interrupted"
  | "conflict"
  | "stale"
  | "ready-to-send"
  | "sending"
  | "send-unknown";

export interface ConversationDestination {
  workspaceId: string;
  channelId: string;
  threadTs: string | null;
}

export interface TaskView {
  id: string;
  workspaceId: string;
  destination: ConversationDestination;
  kind: "review" | "summary";
  status: TaskStatus;
  title: string;
  conversation: string;
  createdAt: number;
  updatedAt: number;
  url?: string | undefined;
  original?: string | undefined;
  suggestion?: string | undefined;
  assessment?: string | undefined;
  coreQuestion?: string | undefined;
  summary?: StoredCard | undefined;
  tools: ToolEvent[];
  error?: string | undefined;
  progress?: string | undefined;
}

export interface TaskEntry {
  targetId: string;
  contextId: number;
  view: TaskView;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function hasErrorCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code;
}
