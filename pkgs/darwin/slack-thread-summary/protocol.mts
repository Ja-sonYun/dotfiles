import { isRecord } from "./contracts.mjs";

export interface DebugTarget {
  id: string;
  type: string;
  url: string;
  webSocketDebuggerUrl: string;
}

export interface BindingEvent {
  name: string;
  payload: string;
  executionContextId: number;
}

export interface PendingCall {
  resolve(value: Record<string, unknown>): void;
  reject(reason: unknown): void;
  timeout: ReturnType<typeof setTimeout>;
}

export function parseTargets(value: unknown): DebugTarget[] {
  if (!Array.isArray(value))
    throw new Error("Invalid Slack debugger target list.");
  return value.filter(
    (target: unknown): target is DebugTarget =>
      isRecord(target) &&
      typeof target.id === "string" &&
      typeof target.type === "string" &&
      typeof target.url === "string" &&
      typeof target.webSocketDebuggerUrl === "string",
  );
}

export function parseBinding(value: unknown): BindingEvent {
  if (
    !isRecord(value) ||
    typeof value.name !== "string" ||
    typeof value.payload !== "string" ||
    typeof value.executionContextId !== "number"
  )
    throw new Error("Invalid Slack debugger binding.");
  return {
    name: value.name,
    payload: value.payload,
    executionContextId: value.executionContextId,
  };
}

export function parseMessage(data: unknown): Record<string, unknown> {
  if (typeof data !== "string")
    throw new Error("Invalid Slack debugger message.");
  const value: unknown = JSON.parse(data);
  if (!isRecord(value)) throw new Error("Invalid Slack debugger message.");
  return value;
}

export function evaluationValue(result: Record<string, unknown>): unknown {
  if (isRecord(result.exceptionDetails)) {
    const exception = result.exceptionDetails.exception;
    const description = isRecord(exception) ? exception.description : undefined;
    throw new Error(
      typeof description === "string"
        ? description
        : typeof result.exceptionDetails.text === "string"
          ? result.exceptionDetails.text
          : "Slack evaluation failed.",
    );
  }
  if (!isRecord(result.result))
    throw new Error("Invalid Slack evaluation result.");
  return result.result.value;
}
