// Vendored from Pi v1.1.0 under the MIT license; see LICENSE.
// https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/examples/extensions/subagent/index.ts

import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
import type { AgentScope } from "./agents.ts";

export interface UsageStats {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  contextTokens: number;
  turns: number;
}

export interface SingleResult {
  agent: string;
  agentSource: "user" | "project" | "unknown";
  task: string;
  exitCode: number;
  messages: Message[];
  stderr: string;
  usage: UsageStats;
  model?: string;
  stopReason?: string;
  errorMessage?: string;
  step?: number;
  activity?: string;
}

export interface SubagentDetails {
  mode: "single" | "parallel" | "chain";
  agentScope: AgentScope;
  projectAgentsDir: string | null;
  results: SingleResult[];
  summary?: string;
  background?: { id: string; state: BackgroundRun["state"] };
}

export interface BackgroundRun {
  id: string;
  sessionId: string;
  state: "running" | "completed" | "failed" | "cancelled";
  controller: AbortController;
  tasks: { agent: string; task: string }[];
  details: SubagentDetails;
  result?: AgentToolResult<SubagentDetails>;
  done?: Promise<void>;
}

export function getFinalOutput(messages: Message[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role === "assistant") {
      for (const part of msg.content) {
        if (part.type === "text") return part.text;
      }
    }
  }
  return "";
}

export function isFailedResult(result: SingleResult): boolean {
  return (
    result.exitCode !== 0 ||
    result.stopReason === "error" ||
    result.stopReason === "aborted"
  );
}

export function getResultOutput(result: SingleResult): string {
  if (isFailedResult(result)) {
    return (
      result.errorMessage ||
      result.stderr ||
      getFinalOutput(result.messages) ||
      "(no output)"
    );
  }
  return getFinalOutput(result.messages) || "(no output)";
}
export function resultCounts(results: SingleResult[]): string {
  const counts = { completed: 0, failed: 0, cancelled: 0 };
  for (const result of results) {
    if (result.exitCode === -1) continue;
    const status =
      result.stopReason === "aborted"
        ? "cancelled"
        : isFailedResult(result)
          ? "failed"
          : "completed";
    counts[status]++;
  }
  return Object.entries(counts)
    .filter(([, count]) => count > 0)
    .map(([status, count]) => `${count} ${status}`)
    .join(", ");
}
export async function mapWithConcurrencyLimit<TIn, TOut>(
  items: TIn[],
  concurrency: number,
  fn: (item: TIn, index: number) => Promise<TOut>,
): Promise<TOut[]> {
  if (items.length === 0) return [];
  const limit = Math.max(1, Math.min(concurrency, items.length));
  const results: TOut[] = new Array(items.length);
  let nextIndex = 0;
  const workers = new Array(limit).fill(null).map(async () => {
    while (true) {
      const current = nextIndex++;
      if (current >= items.length) return;
      results[current] = await fn(items[current], current);
    }
  });
  // Do not release the dispatch permissions while another worker is still running.
  const completions = await Promise.allSettled(workers);
  const failure = completions.find((result) => result.status === "rejected");
  if (failure?.status === "rejected") throw failure.reason;
  return results;
}
