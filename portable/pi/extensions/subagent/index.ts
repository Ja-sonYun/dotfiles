// Vendored from Pi v1.1.0 under the MIT license; see LICENSE.
// https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/examples/extensions/subagent/index.ts

/**
 * Subagent Tool - Delegate tasks to specialized agents
 *
 * Spawns a separate `pi` process for each subagent invocation,
 * giving it an isolated context window.
 *
 * Supports three modes:
 *   - Single: { agent: "name", task: "..." }
 *   - Parallel: { tasks: [{ agent: "name", task: "..." }, ...] }
 *   - Chain: { chain: [{ agent: "name", task: "... {previous} ..." }, ...] }
 *
 * Uses JSON mode to capture structured output from subagents.
 * Runs in the background by default; status and cancellation use the returned run ID.
 */

import { spawn } from "node:child_process";
import { connectPermissions, type PermissionBridge } from "./permissions.ts";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type {
  AgentToolResult,
  ThinkingLevel,
} from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
import { StringEnum } from "@earendil-works/pi-ai";
import {
  CONFIG_DIR_NAME,
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  getMarkdownTheme,
  keyHint,
  withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import {
  Container,
  Markdown,
  Spacer,
  Text,
  stripTerminalSequences,
  truncateToWidth,
} from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { type AgentConfig, type AgentScope, discoverAgents } from "./agents.ts";

const MAX_PARALLEL_TASKS = 8;
const MAX_CONCURRENCY = 4;
const COLLAPSED_ITEM_COUNT = 10;
const PER_TASK_OUTPUT_CAP = 50 * 1024;

function formatTokens(count: number): string {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  return `${(count / 1000000).toFixed(1)}M`;
}

function formatUsageStats(
  usage: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    cost: number;
    contextTokens?: number;
    turns?: number;
  },
  model?: string,
): string {
  const parts: string[] = [];
  if (usage.turns)
    parts.push(`${usage.turns} turn${usage.turns > 1 ? "s" : ""}`);
  if (usage.input) parts.push(`↑${formatTokens(usage.input)}`);
  if (usage.output) parts.push(`↓${formatTokens(usage.output)}`);
  if (usage.cacheRead) parts.push(`R${formatTokens(usage.cacheRead)}`);
  if (usage.cacheWrite) parts.push(`W${formatTokens(usage.cacheWrite)}`);
  if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
  if (usage.contextTokens && usage.contextTokens > 0) {
    parts.push(`ctx:${formatTokens(usage.contextTokens)}`);
  }
  if (model) parts.push(model);
  return parts.join(" ");
}

function formatToolCall(
  toolName: string,
  args: Record<string, unknown>,
  themeFg: (color: any, text: string) => string,
): string {
  const shortenPath = (p: string) => {
    const home = os.homedir();
    return p.startsWith(home) ? `~${p.slice(home.length)}` : p;
  };

  switch (toolName) {
    case "bash": {
      const command = (args.command as string) || "...";
      const preview =
        command.length > 60 ? `${command.slice(0, 60)}...` : command;
      return themeFg("muted", "$ ") + themeFg("toolOutput", preview);
    }
    case "read": {
      const rawPath = (args.file_path || args.path || "...") as string;
      const filePath = shortenPath(rawPath);
      const offset = args.offset as number | undefined;
      const limit = args.limit as number | undefined;
      let text = themeFg("accent", filePath);
      if (offset !== undefined || limit !== undefined) {
        const startLine = offset ?? 1;
        const endLine = limit !== undefined ? startLine + limit - 1 : "";
        text += themeFg(
          "warning",
          `:${startLine}${endLine ? `-${endLine}` : ""}`,
        );
      }
      return themeFg("muted", "read ") + text;
    }
    case "write": {
      const rawPath = (args.file_path || args.path || "...") as string;
      const filePath = shortenPath(rawPath);
      const content = (args.content || "") as string;
      const lines = content.split("\n").length;
      let text = themeFg("muted", "write ") + themeFg("accent", filePath);
      if (lines > 1) text += themeFg("dim", ` (${lines} lines)`);
      return text;
    }
    case "edit": {
      const rawPath = (args.file_path || args.path || "...") as string;
      return (
        themeFg("muted", "edit ") + themeFg("accent", shortenPath(rawPath))
      );
    }
    case "ls": {
      const rawPath = (args.path || ".") as string;
      return themeFg("muted", "ls ") + themeFg("accent", shortenPath(rawPath));
    }
    case "find": {
      const pattern = (args.pattern || "*") as string;
      const rawPath = (args.path || ".") as string;
      return (
        themeFg("muted", "find ") +
        themeFg("accent", pattern) +
        themeFg("dim", ` in ${shortenPath(rawPath)}`)
      );
    }
    case "grep": {
      const pattern = (args.pattern || "") as string;
      const rawPath = (args.path || ".") as string;
      return (
        themeFg("muted", "grep ") +
        themeFg("accent", `/${pattern}/`) +
        themeFg("dim", ` in ${shortenPath(rawPath)}`)
      );
    }
    default: {
      const argsStr = JSON.stringify(args);
      const preview =
        argsStr.length > 50 ? `${argsStr.slice(0, 50)}...` : argsStr;
      return themeFg("accent", toolName) + themeFg("dim", ` ${preview}`);
    }
  }
}

interface UsageStats {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  contextTokens: number;
  turns: number;
}

interface SingleResult {
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

interface SubagentDetails {
  mode: "single" | "parallel" | "chain";
  agentScope: AgentScope;
  projectAgentsDir: string | null;
  results: SingleResult[];
  summary?: string;
  background?: { id: string; state: BackgroundRun["state"] };
}

interface BackgroundRun {
  id: string;
  sessionId: string;
  state: "running" | "completed" | "failed" | "cancelled";
  controller: AbortController;
  tasks: { agent: string; task: string }[];
  details: SubagentDetails;
  result?: AgentToolResult<SubagentDetails>;
  done?: Promise<void>;
}

function getFinalOutput(messages: Message[]): string {
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

function isFailedResult(result: SingleResult): boolean {
  return (
    result.exitCode !== 0 ||
    result.stopReason === "error" ||
    result.stopReason === "aborted"
  );
}

function getResultOutput(result: SingleResult): string {
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

function diagnosticLine(text: string): string {
  return (
    stripTerminalSequences(text)
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line && line !== "Script error:")
      ?.replace(/\s+/g, " ") ?? ""
  );
}

function resultCounts(results: SingleResult[]): string {
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

function truncateParallelOutput(output: string): string {
  const byteLength = Buffer.byteLength(output, "utf8");
  if (byteLength <= PER_TASK_OUTPUT_CAP) return output;

  let truncated = output.slice(0, PER_TASK_OUTPUT_CAP);
  while (Buffer.byteLength(truncated, "utf8") > PER_TASK_OUTPUT_CAP) {
    truncated = truncated.slice(0, -1);
  }
  return `${truncated}\n\n[Output truncated: ${byteLength - Buffer.byteLength(truncated, "utf8")} bytes omitted. Full output preserved in tool details.]`;
}

type DisplayItem =
  | { type: "text"; text: string }
  | { type: "toolCall"; name: string; args: Record<string, any> };

function getDisplayItems(messages: Message[]): DisplayItem[] {
  const items: DisplayItem[] = [];
  for (const msg of messages) {
    if (msg.role === "assistant") {
      for (const part of msg.content) {
        if (part.type === "text") items.push({ type: "text", text: part.text });
        else if (part.type === "toolCall")
          items.push({
            type: "toolCall",
            name: part.name,
            args: part.arguments,
          });
      }
    }
  }
  return items;
}

async function mapWithConcurrencyLimit<TIn, TOut>(
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

async function writePromptToTempFile(
  agentName: string,
  prompt: string,
): Promise<{ dir: string; filePath: string }> {
  const tmpDir = await fs.promises.mkdtemp(
    path.join(os.tmpdir(), "pi-subagent-"),
  );
  const safeName = agentName.replace(/[^\w.-]+/g, "_");
  const filePath = path.join(tmpDir, `prompt-${safeName}.md`);
  await withFileMutationQueue(filePath, async () => {
    await fs.promises.writeFile(filePath, prompt, {
      encoding: "utf-8",
      mode: 0o600,
    });
  });
  return { dir: tmpDir, filePath };
}

type OnUpdateCallback = (partial: AgentToolResult<SubagentDetails>) => void;

interface DispatchDefaults {
  model?: string;
  thinkingLevel?: ThinkingLevel;
  permissions: (
    agent: AgentConfig,
    task: string,
    cwd: string,
  ) => PermissionBridge | undefined;
}

async function runSingleAgent(
  defaultCwd: string,
  dispatchDefaults: DispatchDefaults,
  agents: AgentConfig[],
  agentName: string,
  task: string,
  cwd: string | undefined,
  step: number | undefined,
  signal: AbortSignal | undefined,
  onUpdate: OnUpdateCallback | undefined,
  makeDetails: (results: SingleResult[]) => SubagentDetails,
): Promise<SingleResult> {
  const agent = agents.find((a) => a.name === agentName);

  if (!agent) {
    const available = agents.map((a) => `"${a.name}"`).join(", ") || "none";
    return {
      agent: agentName,
      agentSource: "unknown",
      task,
      exitCode: 1,
      messages: [],
      stderr: `Unknown agent: "${agentName}". Available agents: ${available}.`,
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        cost: 0,
        contextTokens: 0,
        turns: 0,
      },
      step,
    };
  }

  const args: string[] = [
    "--mode",
    "json",
    "-p",
    "--no-session",
    "--exclude-tools",
    "subagent",
  ];
  const inheritsDispatchConfig = !agent.model;
  const model = agent.model ?? dispatchDefaults.model;
  if (model) args.push("--model", model);
  if (inheritsDispatchConfig && dispatchDefaults.thinkingLevel) {
    args.push("--thinking", dispatchDefaults.thinkingLevel);
  }
  if (agent.tools && agent.tools.length > 0)
    args.push("--tools", agent.tools.join(","));

  let tmpPromptDir: string | null = null;
  let tmpPromptPath: string | null = null;

  const currentResult: SingleResult = {
    agent: agentName,
    agentSource: agent.source,
    task,
    exitCode: -1,
    messages: [],
    stderr: "",
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      cost: 0,
      contextTokens: 0,
      turns: 0,
    },
    model,
    step,
  };

  const executionCwd = path.resolve(defaultCwd, cwd ?? ".");
  const permissions = dispatchDefaults.permissions(agent, task, executionCwd);
  if (!permissions) {
    currentResult.exitCode = 1;
    currentResult.stderr =
      `Agent "${agentName}" requires permissionMode "${String(agent.permissionMode)}"; ` +
      "The parent permission extension is required and must support this mode.";
    return currentResult;
  }
  args.push("--extension", permissions.extension);

  const emitUpdate = () => {
    if (onUpdate) {
      onUpdate({
        content: [
          {
            type: "text",
            text: getFinalOutput(currentResult.messages) || "(running...)",
          },
        ],
        details: makeDetails([currentResult]),
      });
    }
  };

  try {
    if (signal?.aborted) {
      currentResult.exitCode = 1;
      currentResult.stopReason = "aborted";
      currentResult.errorMessage = "Subagent was cancelled";
      return currentResult;
    }
    emitUpdate();
    if (agent.systemPrompt.trim()) {
      const tmp = await writePromptToTempFile(agent.name, agent.systemPrompt);
      tmpPromptDir = tmp.dir;
      tmpPromptPath = tmp.filePath;
      args.push("--append-system-prompt", tmpPromptPath);
    }

    args.push(`Task: ${task}`);
    let wasAborted = false;

    const exitCode = await new Promise<number>((resolve, reject) => {
      const proc = spawn(process.env.PI_EXECUTABLE ?? "pi", args, {
        cwd: executionCwd,
        shell: false,
        detached: true,
        stdio: ["ignore", "pipe", "pipe", "ipc"],
        env: {
          ...process.env,
          PI_PERMISSION_CHILD: "1",
          PI_PERMISSION_MODE: permissions.mode,
        },
      });
      connectPermissions(proc, permissions, signal);
      let buffer = "";

      const processLine = (line: string) => {
        if (!line.trim()) return;
        let event: any;
        try {
          event = JSON.parse(line);
        } catch {
          return;
        }

        if (event.type === "tool_execution_start") {
          currentResult.activity = event.toolName;
          emitUpdate();
        }
        if (event.type === "tool_execution_end") {
          currentResult.activity = undefined;
          emitUpdate();
        }

        if (event.type === "message_end" && event.message) {
          const msg = event.message as Message;
          currentResult.messages.push(msg);

          if (msg.role === "assistant") {
            currentResult.usage.turns++;
            const usage = msg.usage;
            if (usage) {
              currentResult.usage.input += usage.input || 0;
              currentResult.usage.output += usage.output || 0;
              currentResult.usage.cacheRead += usage.cacheRead || 0;
              currentResult.usage.cacheWrite += usage.cacheWrite || 0;
              currentResult.usage.cost += usage.cost?.total || 0;
              currentResult.usage.contextTokens = usage.totalTokens || 0;
            }
            if (!currentResult.model && msg.model)
              currentResult.model = msg.model;
            if (msg.stopReason) currentResult.stopReason = msg.stopReason;
            if (msg.errorMessage) currentResult.errorMessage = msg.errorMessage;
          }
          emitUpdate();
        }

        if (event.type === "tool_result_end" && event.message) {
          currentResult.messages.push(event.message as Message);
          emitUpdate();
        }
      };

      proc.stdout.on("data", (data) => {
        buffer += data.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";
        for (const line of lines) processLine(line);
      });

      proc.stderr.on("data", (data) => {
        currentResult.stderr += data.toString();
      });

      let cancellation: Promise<void> | undefined;
      const processGroup = proc.pid;
      const signalGroup = (groupSignal: NodeJS.Signals | 0): boolean => {
        if (processGroup === undefined) return false;
        try {
          process.kill(-processGroup, groupSignal);
          return true;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
          throw error;
        }
      };

      const killProc = () => {
        wasAborted = true;
        if (cancellation) return;
        cancellation = (async () => {
          if (!signalGroup("SIGTERM")) return;
          const deadline = Date.now() + 5000;
          while (Date.now() < deadline) {
            if (!signalGroup(0)) return;
            await new Promise<void>((done) => setTimeout(done, 50));
          }
          if (signalGroup(0)) signalGroup("SIGKILL");
        })();
        cancellation.catch(reject);
      };

      proc.on("close", (code) => {
        signal?.removeEventListener("abort", killProc);
        if (buffer.trim()) processLine(buffer);
        (cancellation ?? Promise.resolve()).then(
          () => resolve(code ?? 1),
          reject,
        );
      });

      proc.on("error", (error) => {
        currentResult.stderr += error.message;
      });

      if (signal?.aborted) killProc();
      else signal?.addEventListener("abort", killProc, { once: true });
    });

    currentResult.exitCode = exitCode;
    if (wasAborted) {
      currentResult.exitCode = 1;
      currentResult.stopReason = "aborted";
      currentResult.errorMessage = "Subagent was cancelled";
    }
    return currentResult;
  } catch (error) {
    currentResult.exitCode = 1;
    currentResult.stopReason = signal?.aborted ? "aborted" : "error";
    currentResult.errorMessage =
      error instanceof Error ? error.message : String(error);
    return currentResult;
  } finally {
    if (tmpPromptPath)
      try {
        fs.unlinkSync(tmpPromptPath);
      } catch {
        /* ignore */
      }
    if (tmpPromptDir)
      try {
        fs.rmdirSync(tmpPromptDir);
      } catch {
        /* ignore */
      }
  }
}

const TaskItem = Type.Object({
  agent: Type.String({ description: "Name of the agent to invoke" }),
  task: Type.String({ description: "Task to delegate to the agent" }),
  cwd: Type.Optional(
    Type.String({ description: "Working directory for the agent process" }),
  ),
});

const ChainItem = Type.Object({
  agent: Type.String({ description: "Name of the agent to invoke" }),
  task: Type.String({
    description: "Task with optional {previous} placeholder for prior output",
  }),
  cwd: Type.Optional(
    Type.String({ description: "Working directory for the agent process" }),
  ),
});

const AgentScopeSchema = StringEnum(["user", "project", "both"] as const, {
  description:
    'Which agent directories to use. Default: "user". Use "both" to include project-local agents.',
  default: "user",
});

const SubagentParams = Type.Object({
  action: Type.Optional(
    StringEnum(["run", "status", "cancel"] as const, {
      description:
        "Start agents, inspect background runs, or cancel a run. Default: run.",
    }),
  ),
  runId: Type.Optional(
    Type.String({
      description:
        "Background run ID for status or cancel. Omit for status of all runs.",
    }),
  ),
  background: Type.Optional(
    Type.Boolean({
      description:
        "Return a run ID immediately and continue working. Default: true. Set false to wait for results.",
      default: true,
    }),
  ),
  agent: Type.Optional(
    Type.String({
      description: "Name of the agent to invoke (for single mode)",
    }),
  ),
  task: Type.Optional(
    Type.String({ description: "Task to delegate (for single mode)" }),
  ),
  tasks: Type.Optional(
    Type.Array(TaskItem, {
      description: "Array of {agent, task} for parallel execution",
    }),
  ),
  chain: Type.Optional(
    Type.Array(ChainItem, {
      description: "Array of {agent, task} for sequential execution",
    }),
  ),
  agentScope: Type.Optional(AgentScopeSchema),
  confirmProjectAgents: Type.Optional(
    Type.Boolean({
      description: "Prompt before running project-local agents. Default: true.",
      default: true,
    }),
  ),
  cwd: Type.Optional(
    Type.String({
      description: "Working directory for the agent process (single mode)",
    }),
  ),
});

export default function (pi: ExtensionAPI) {
  const runs = new Map<string, BackgroundRun>();
  let nextRun = 0;
  let context: ExtensionContext | undefined;

  const stateLabel = {
    running: "running",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled",
  } as const;
  const stateColor = {
    running: "warning",
    completed: "success",
    failed: "error",
    cancelled: "warning",
    pending: "muted",
    "not run": "dim",
  } as const;

  function refreshWidget() {
    if (!context?.hasUI) return;
    if (![...runs.values()].some((run) => run.state === "running")) {
      context.ui.setWidget("subagents", undefined);
      return;
    }
    context.ui.setWidget("subagents", (_tui, theme) => ({
      render(width) {
        const lines = [
          theme.fg("accent", theme.bold("Subagents")) +
            theme.fg("muted", " · /agents status · output · cancel"),
        ];
        const tasks = [...runs.values()]
          .filter((run) => run.state === "running")
          .flatMap((run) =>
            run.tasks.map((task, index) => ({
              run,
              task,
              index,
              result: run.details.results[index],
            })),
          )
          .filter(
            ({ result }) =>
              !result || result.exitCode === -1 || isFailedResult(result),
          );
        for (const { run, task, index, result } of tasks) {
          const status = result
            ? result.exitCode === -1
              ? stateLabel[run.state]
              : result.stopReason === "aborted"
                ? "cancelled"
                : isFailedResult(result)
                  ? "failed"
                  : "completed"
            : run.state === "running"
              ? "pending"
              : "not run";
          const activity = result?.activity
            ? theme.fg(
                "muted",
                ` · ${stripTerminalSequences(result.activity).replace(/[\r\n\t]/g, " ")}`,
              )
            : "";
          lines.push(
            "  " +
              theme.fg(
                "accent",
                theme.bold(
                  stripTerminalSequences(task.agent).replace(/[\r\n\t]/g, " "),
                ),
              ) +
              (tasks.filter((item) => item.task.agent === task.agent).length > 1
                ? theme.fg("dim", ` [${run.id}/${index + 1}]`)
                : "") +
              theme.fg("dim", " · ") +
              theme.fg(stateColor[status], status) +
              activity,
          );
        }
        return lines.map((line) =>
          truncateToWidth(line, Math.max(1, Math.min(width, 120)), "…"),
        );
      },
      invalidate() {},
    }));
  }

  const clearRuns = async (_event: unknown, ctx: ExtensionContext) => {
    const pending = [...runs.values()];
    runs.clear();
    for (const run of pending) run.controller.abort();
    if (context?.hasUI) context.ui.setWidget("subagents", undefined);
    await Promise.allSettled(pending.map((run) => run.done));
    context = ctx;
  };
  pi.on("session_start", clearRuns);
  pi.on("session_before_switch", clearRuns);
  pi.on("session_before_fork", clearRuns);
  pi.on("session_before_tree", clearRuns);
  pi.on("session_shutdown", clearRuns);

  pi.registerMessageRenderer<SubagentDetails>(
    "subagent-background",
    (message, { expanded, outputPad }, theme) => {
      const background = message.details?.background;
      if (!background) return undefined;
      const text =
        typeof message.content === "string"
          ? message.content
          : message.content
              .filter((part) => part.type === "text")
              .map((part) => part.text)
              .join("\n\n");
      if (expanded) {
        return new Markdown(text, outputPad, 0, getMarkdownTheme());
      }
      const counts =
        background.state === "completed"
          ? ""
          : resultCounts(message.details?.results ?? []);
      const label =
        theme.fg(
          stateColor[background.state],
          `${background.state === "completed" ? "✓" : background.state === "failed" ? "✗" : background.state === "cancelled" ? "■" : "…"} `,
        ) +
        theme.fg("text", message.details?.summary ?? background.id) +
        theme.fg(
          "muted",
          ` · ${stateLabel[background.state]}${counts ? ` · ${counts}` : ""} ${keyHint("app.tools.expand", "details")}`,
        );
      const diagnostics =
        background.state === "completed"
          ? ""
          : diagnosticLine(
              message.details?.results
                .filter((item) => item.exitCode !== -1 && isFailedResult(item))
                .map(getResultOutput)
                .join("\n\n") || text.split("\n").slice(2).join("\n"),
            );
      const lines = [label];
      if (diagnostics) lines.push(theme.fg("toolOutput", diagnostics));
      return {
        render: (width) =>
          lines.map(
            (line) =>
              " ".repeat(outputPad) +
              truncateToWidth(
                line,
                Math.max(1, Math.min(width - outputPad * 2, 120)),
                "…",
              ),
          ),
        invalidate() {},
      };
    },
  );

  pi.registerCommand("agents", {
    description:
      "List runs; /agents <runId> shows output; /agents cancel <runId> stops a run",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return;
      context = ctx;
      const choices = [...runs.values()].map(
        (run) =>
          `${run.id} · ${stateLabel[run.state]} · ${run.tasks.map((task) => task.agent).join(", ")}`,
      );
      if (choices.length === 0) {
        ctx.ui.notify("No background runs.", "info");
        return;
      }
      if (!args.trim()) {
        ctx.ui.notify(
          `${choices.join("\n")}\n/agents <runId> · /agents cancel <runId>`,
          "info",
        );
        return;
      }
      const [action, id] = args.trim().split(/\s+/);
      const run = runs.get(action === "cancel" ? id : action);
      if (!run || run.sessionId !== ctx.sessionManager.getSessionId()) {
        ctx.ui.notify("Run not found in the current session.", "warning");
        return;
      }
      if (action === "cancel") {
        run.controller.abort();
        await run.done;
      } else {
        const output =
          run.result?.content
            .filter((part) => part.type === "text")
            .map((part) => part.text)
            .join("\n\n") ||
          run.details.results.map(getResultOutput).join("\n\n") ||
          "No output yet.";
        ctx.ui.notify(
          `${run.id} · ${stateLabel[run.state]}\n${stripTerminalSequences(output)}`,
          "info",
        );
      }
    },
  });

  pi.registerTool({
    name: "subagent",
    label: "Subagent",
    description: [
      "Delegate tasks to specialized subagents with isolated context.",
      "Modes: single (agent + task), parallel (tasks array), chain (sequential with {previous} placeholder).",
      "Runs in the background by default and returns a runId. Continue other work; use action status or cancel with runId. Set background false to wait.",
      `Default agent scope is "user" (from ${path.join(getAgentDir(), "agents")}).`,
      `To enable project-local agents in ${CONFIG_DIR_NAME}/agents, set agentScope: "both" (or "project").`,
    ].join(" "),
    parameters: SubagentParams,

    async execute(
      _toolCallId,
      params,
      signal,
      onUpdate,
      ctx,
    ): Promise<AgentToolResult<SubagentDetails | undefined>> {
      context = ctx;
      // Retain the generated Korean summary for this dispatch and its completion message.
      let summary: string | undefined;
      pi.events.emit("tool-summaries:get", {
        toolCallId: _toolCallId,
        reply: (text: string | undefined) => {
          summary = text;
        },
      });
      if (params.action === "status" || params.action === "cancel") {
        if (params.action === "status" && !params.runId) {
          return {
            content: [
              {
                type: "text",
                text:
                  [...runs.values()]
                    .map(
                      (run) =>
                        `${run.id}: ${run.state} (${run.tasks.map((task) => task.agent).join(", ")})`,
                    )
                    .join("\n") || "No background runs.",
              },
            ],
            details: undefined,
          };
        }
        const run = runs.get(params.runId ?? "");
        if (!run || run.sessionId !== ctx.sessionManager.getSessionId()) {
          return {
            content: [
              { type: "text", text: "Unknown background run in this session." },
            ],
            details: undefined,
            isError: true,
          };
        }
        if (params.action === "cancel" && run.state === "running") {
          run.controller.abort();
          await run.done;
          if (
            runs.get(run.id) !== run ||
            ctx.sessionManager.getSessionId() !== run.sessionId
          ) {
            return {
              content: [
                { type: "text", text: "The background run's session changed." },
              ],
              details: undefined,
              isError: true,
            };
          }
        }
        return (
          run.result ?? {
            content: [{ type: "text", text: `${run.id}: ${run.state}` }],
            details: {
              ...run.details,
              background: { id: run.id, state: run.state },
            },
          }
        );
      }
      params = structuredClone(params);
      const dispatchCwd = ctx.cwd;
      const sessionId = ctx.sessionManager.getSessionId();
      const agentScope: AgentScope = params.agentScope ?? "user";
      const dispatchDefaults: DispatchDefaults = {
        model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined,
        thinkingLevel: ctx.thinkingLevel,
        permissions: (agent, task, cwd) => {
          let bridge: PermissionBridge | undefined;
          pi.events.emit("permissions:child", {
            dispatchId: _toolCallId,
            name: agent.name,
            mode: agent.permissionMode,
            task,
            cwd,
            reply: (value: PermissionBridge) => {
              bridge = value;
            },
          });
          return bridge;
        },
      };
      const discovery = discoverAgents(ctx.cwd, agentScope);
      const agents = discovery.agents;
      const confirmProjectAgents = params.confirmProjectAgents ?? true;

      const hasChain = (params.chain?.length ?? 0) > 0;
      const hasTasks = (params.tasks?.length ?? 0) > 0;
      const hasSingle = Boolean(params.agent && params.task);
      const modeCount = Number(hasChain) + Number(hasTasks) + Number(hasSingle);

      const makeDetails =
        (mode: "single" | "parallel" | "chain") =>
        (results: SingleResult[]): SubagentDetails => ({
          mode,
          agentScope,
          projectAgentsDir: discovery.projectAgentsDir,
          results,
          summary,
        });

      if (modeCount !== 1) {
        const available =
          agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
        return {
          content: [
            {
              type: "text",
              text: `Invalid parameters. Provide exactly one mode.\nAvailable agents: ${available}`,
            },
          ],
          details: makeDetails("single")([]),
          isError: true,
        };
      }

      if (
        (agentScope === "project" || agentScope === "both") &&
        confirmProjectAgents &&
        ctx.hasUI &&
        !ctx.isProjectTrusted()
      ) {
        const requestedAgentNames = new Set<string>();
        if (params.chain)
          for (const step of params.chain) requestedAgentNames.add(step.agent);
        if (params.tasks)
          for (const t of params.tasks) requestedAgentNames.add(t.agent);
        if (params.agent) requestedAgentNames.add(params.agent);

        const projectAgentsRequested = Array.from(requestedAgentNames)
          .map((name) => agents.find((a) => a.name === name))
          .filter((a): a is AgentConfig => a?.source === "project");

        if (projectAgentsRequested.length > 0) {
          const names = projectAgentsRequested.map((a) => a.name).join(", ");
          const dir = discovery.projectAgentsDir ?? "(unknown)";
          const ok = await ctx.ui.confirm(
            "Run project-local agents?",
            `Agents: ${names}\nSource: ${dir}\n\nProject agents are repo-controlled. Only continue for trusted repositories.`,
          );
          if (!ok)
            return {
              content: [
                {
                  type: "text",
                  text: "Canceled: project-local agents not approved.",
                },
              ],
              details: makeDetails(
                hasChain ? "chain" : hasTasks ? "parallel" : "single",
              )([]),
              isError: true,
            };
        }
      }

      const runAgents = async (
        signal: AbortSignal | undefined,
        onUpdate: OnUpdateCallback | undefined,
      ): Promise<AgentToolResult<SubagentDetails>> => {
        if (params.chain && params.chain.length > 0) {
          const results: SingleResult[] = [];
          let previousOutput = "";

          for (let i = 0; i < params.chain.length; i++) {
            const step = params.chain[i];
            const taskWithContext = step.task.replace(
              /\{previous\}/g,
              previousOutput,
            );

            // Create update callback that includes all previous results
            const chainUpdate: OnUpdateCallback | undefined = onUpdate
              ? (partial) => {
                  // Combine completed results with current streaming result
                  const currentResult = partial.details?.results[0];
                  if (currentResult) {
                    const allResults = [...results, currentResult];
                    onUpdate({
                      content: partial.content,
                      details: makeDetails("chain")(allResults),
                    });
                  }
                }
              : undefined;

            const result = await runSingleAgent(
              dispatchCwd,
              dispatchDefaults,
              agents,
              step.agent,
              taskWithContext,
              step.cwd,
              i + 1,
              signal,
              chainUpdate,
              makeDetails("chain"),
            );
            results.push(result);

            const isError = isFailedResult(result);
            if (isError) {
              const errorMsg = getResultOutput(result);
              return {
                content: [
                  {
                    type: "text",
                    text: `Chain stopped at step ${i + 1} (${step.agent}): ${errorMsg}`,
                  },
                ],
                details: makeDetails("chain")(results),
                isError: true,
              };
            }
            previousOutput = getFinalOutput(result.messages);
          }
          return {
            content: [
              {
                type: "text",
                text:
                  getFinalOutput(results[results.length - 1].messages) ||
                  "(no output)",
              },
            ],
            details: makeDetails("chain")(results),
          };
        }

        if (params.tasks && params.tasks.length > 0) {
          if (params.tasks.length > MAX_PARALLEL_TASKS)
            return {
              content: [
                {
                  type: "text",
                  text: `Too many parallel tasks (${params.tasks.length}). Max is ${MAX_PARALLEL_TASKS}.`,
                },
              ],
              details: makeDetails("parallel")([]),
              isError: true,
            };

          // Track all results for streaming updates
          const allResults: SingleResult[] = new Array(params.tasks.length);

          // Initialize placeholder results
          for (let i = 0; i < params.tasks.length; i++) {
            allResults[i] = {
              agent: params.tasks[i].agent,
              agentSource: "unknown",
              task: params.tasks[i].task,
              exitCode: -1, // -1 = still running
              messages: [],
              stderr: "",
              usage: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                cost: 0,
                contextTokens: 0,
                turns: 0,
              },
            };
          }

          const emitParallelUpdate = () => {
            if (onUpdate) {
              const running = allResults.filter(
                (r) => r.exitCode === -1,
              ).length;
              const done = allResults.filter((r) => r.exitCode !== -1).length;
              onUpdate({
                content: [
                  {
                    type: "text",
                    text: `Parallel: ${done}/${allResults.length} done, ${running} running...`,
                  },
                ],
                details: makeDetails("parallel")([...allResults]),
              });
            }
          };

          const results = await mapWithConcurrencyLimit(
            params.tasks,
            MAX_CONCURRENCY,
            async (t, index) => {
              const result = await runSingleAgent(
                dispatchCwd,
                dispatchDefaults,
                agents,
                t.agent,
                t.task,
                t.cwd,
                undefined,
                signal,
                // Per-task update callback
                (partial) => {
                  if (partial.details?.results[0]) {
                    allResults[index] = partial.details.results[0];
                    emitParallelUpdate();
                  }
                },
                makeDetails("parallel"),
              );
              allResults[index] = result;
              emitParallelUpdate();
              return result;
            },
          );

          const successCount = results.filter((r) => !isFailedResult(r)).length;
          const summaries = results.map((r) => {
            const output = truncateParallelOutput(getResultOutput(r));
            const status = isFailedResult(r)
              ? `failed${r.stopReason && r.stopReason !== "end" ? ` (${r.stopReason})` : ""}`
              : "completed";
            return `### [${r.agent}] ${status}\n\n${output}`;
          });
          return {
            content: [
              {
                type: "text",
                text: `Parallel: ${successCount}/${results.length} succeeded\n\n${summaries.join("\n\n---\n\n")}`,
              },
            ],
            details: makeDetails("parallel")(results),
            isError: successCount !== results.length,
          };
        }

        if (params.agent && params.task) {
          const result = await runSingleAgent(
            dispatchCwd,
            dispatchDefaults,
            agents,
            params.agent,
            params.task,
            params.cwd,
            undefined,
            signal,
            onUpdate,
            makeDetails("single"),
          );
          const isError = isFailedResult(result);
          if (isError) {
            const errorMsg = getResultOutput(result);
            return {
              content: [
                {
                  type: "text",
                  text: `Agent ${result.stopReason || "failed"}: ${errorMsg}`,
                },
              ],
              details: makeDetails("single")([result]),
              isError: true,
            };
          }
          return {
            content: [
              {
                type: "text",
                text: getFinalOutput(result.messages) || "(no output)",
              },
            ],
            details: makeDetails("single")([result]),
          };
        }

        const available =
          agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
        return {
          content: [
            {
              type: "text",
              text: `Invalid parameters. Available agents: ${available}`,
            },
          ],
          details: makeDetails("single")([]),
        };
      };

      if (params.background === false) return runAgents(signal, onUpdate);
      if (signal?.aborted || ctx.sessionManager.getSessionId() !== sessionId) {
        return {
          content: [{ type: "text", text: "Subagent dispatch was cancelled." }],
          details: undefined,
          isError: true,
        };
      }
      if (
        [...runs.values()].filter((run) => run.state === "running").length >=
        MAX_CONCURRENCY
      ) {
        return {
          content: [
            {
              type: "text",
              text: `At most ${MAX_CONCURRENCY} background runs can be active. Wait for or cancel a run.`,
            },
          ],
          details: undefined,
          isError: true,
        };
      }
      const run: BackgroundRun = {
        id: `run-${++nextRun}`,
        sessionId,
        state: "running",
        controller: new AbortController(),
        tasks: hasChain
          ? params.chain!
          : hasTasks
            ? params.tasks!
            : [{ agent: params.agent!, task: params.task! }],
        details: makeDetails(
          hasChain ? "chain" : hasTasks ? "parallel" : "single",
        )([]),
      };
      let release: (() => void) | undefined;
      pi.events.emit("permissions:background", {
        dispatchId: _toolCallId,
        signal: run.controller.signal,
        cancel: () => run.controller.abort(),
        reply: (value: () => void) => {
          release = value;
        },
      });
      if (!release) {
        return {
          content: [
            {
              type: "text",
              text: "The parent permission extension could not retain this background dispatch.",
            },
          ],
          details: undefined,
          isError: true,
        };
      }
      const releaseDispatch = release;
      runs.set(run.id, run);
      refreshWidget();
      run.done = (async () => {
        try {
          const result = await runAgents(run.controller.signal, (partial) => {
            if (partial.details) run.details = partial.details;
            if (runs.get(run.id) === run) refreshWidget();
          });
          run.state =
            run.controller.signal.aborted ||
            result.details?.results.some(
              (item) => item.stopReason === "aborted",
            )
              ? "cancelled"
              : result.isError || result.details?.results.some(isFailedResult)
                ? "failed"
                : "completed";
          run.result = {
            ...result,
            details: {
              ...(result.details ?? run.details),
              background: { id: run.id, state: run.state },
            },
          };
        } catch (error) {
          run.state = run.controller.signal.aborted ? "cancelled" : "failed";
          run.result = {
            content: [
              {
                type: "text",
                text: error instanceof Error ? error.message : String(error),
              },
            ],
            details: {
              ...run.details,
              background: { id: run.id, state: run.state },
            },
            isError: true,
          };
        } finally {
          releaseDispatch();
        }
        run.details = run.result.details;
        if (
          runs.get(run.id) !== run ||
          ctx.sessionManager.getSessionId() !== sessionId
        )
          return;
        refreshWidget();
        pi.sendMessage(
          {
            customType: "subagent-background",
            content: `${run.id}: ${run.state}\n\n${truncateParallelOutput(
              run.result.content
                .filter((part) => part.type === "text")
                .map((part) => part.text)
                .join("\n\n"),
            )}`,
            display: true,
            details: run.result.details,
          },
          { triggerTurn: false },
        );
      })();
      return {
        content: [
          {
            type: "text",
            text: `Started ${run.id} in the background. Continue other work; use subagent action status or cancel with runId "${run.id}". Completion will be reported without starting a new turn.`,
          },
        ],
        details: {
          ...run.details,
          background: { id: run.id, state: "running" },
        },
      };
    },

    renderCall(args, theme, context) {
      if (!context.isPartial && !context.expanded) {
        return new Container();
      }
      if (args.action && args.action !== "run") {
        return new Text(
          theme.fg("toolTitle", theme.bold("subagent ")) +
            theme.fg("accent", `${args.action} ${args.runId ?? "all"}`),
          0,
          0,
        );
      }
      const scope: AgentScope = args.agentScope ?? "user";
      const execution = args.background === false ? "foreground" : "background";
      if (args.chain && args.chain.length > 0) {
        let text =
          theme.fg("toolTitle", theme.bold("subagent ")) +
          theme.fg("accent", `chain (${args.chain.length} steps)`) +
          theme.fg("muted", ` [${scope} · ${execution}]`);
        for (let i = 0; i < Math.min(args.chain.length, 3); i++) {
          const step = args.chain[i];
          // Clean up {previous} placeholder for display
          const cleanTask = step.task.replace(/\{previous\}/g, "").trim();
          const preview =
            cleanTask.length > 40 ? `${cleanTask.slice(0, 40)}...` : cleanTask;
          text +=
            "\n  " +
            theme.fg("muted", `${i + 1}.`) +
            " " +
            theme.fg("accent", step.agent) +
            theme.fg("dim", ` ${preview}`);
        }
        if (args.chain.length > 3)
          text += `\n  ${theme.fg("muted", `... +${args.chain.length - 3} more`)}`;
        return new Text(text, 0, 0);
      }
      if (args.tasks && args.tasks.length > 0) {
        let text =
          theme.fg("toolTitle", theme.bold("subagent ")) +
          theme.fg("accent", `parallel (${args.tasks.length} tasks)`) +
          theme.fg("muted", ` [${scope} · ${execution}]`);
        for (const t of args.tasks.slice(0, 3)) {
          const preview =
            t.task.length > 40 ? `${t.task.slice(0, 40)}...` : t.task;
          text += `\n  ${theme.fg("accent", t.agent)}${theme.fg("dim", ` ${preview}`)}`;
        }
        if (args.tasks.length > 3)
          text += `\n  ${theme.fg("muted", `... +${args.tasks.length - 3} more`)}`;
        return new Text(text, 0, 0);
      }
      const agentName = args.agent || "...";
      const preview = args.task
        ? args.task.length > 60
          ? `${args.task.slice(0, 60)}...`
          : args.task
        : "...";
      let text =
        theme.fg("toolTitle", theme.bold("subagent ")) +
        theme.fg("accent", agentName) +
        theme.fg("muted", ` [${scope} · ${execution}]`);
      text += `\n  ${theme.fg("dim", preview)}`;
      return new Text(text, 0, 0);
    },

    renderResult(result, { expanded }, theme, context) {
      const details = result.details as SubagentDetails | undefined;
      if (!expanded && (details?.background || !context.isPartial)) {
        let summary = details?.summary;
        pi.events.emit("tool-summaries:get", {
          toolCallId: context.toolCallId,
          reply: (text: string | undefined) => {
            if (text) summary = text;
          },
        });
        const state =
          details?.background?.state ??
          (context.isPartial
            ? "running"
            : details?.results.some((item) => item.stopReason === "aborted")
              ? "cancelled"
              : context.isError || details?.results.some(isFailedResult)
                ? "failed"
                : "completed");
        const counts =
          state === "failed" || state === "cancelled"
            ? resultCounts(details?.results ?? [])
            : "";
        const label =
          theme.fg(
            stateColor[state],
            `${state === "completed" ? "✓" : state === "failed" ? "✗" : state === "cancelled" ? "■" : "…"} `,
          ) +
          theme.fg("text", summary ?? "subagent") +
          theme.fg(
            "muted",
            `${details?.background ? " · background" : ""}${counts ? ` · ${counts}` : ""}${context.durationMs === undefined ? "" : ` · ${(context.durationMs / 1000).toFixed(1)}s`} ${keyHint("app.tools.expand", "details")}`,
          );
        const lines = [label];
        if (state === "failed" || state === "cancelled") {
          const diagnostics = diagnosticLine(
            details?.results
              .filter((item) => item.exitCode !== -1 && isFailedResult(item))
              .map(getResultOutput)
              .join("\n\n") ||
              result.content
                .filter((part) => part.type === "text")
                .map((part) => part.text)
                .join("\n\n"),
          );
          if (diagnostics) {
            lines.push(theme.fg("toolOutput", diagnostics));
          }
        }
        return {
          render: (width) =>
            lines.map((line) =>
              truncateToWidth(line, Math.max(1, Math.min(width, 120)), "…"),
            ),
          invalidate() {},
        };
      }
      if (!details || details.results.length === 0) {
        const text = result.content[0];
        return new Text(
          text?.type === "text" ? text.text : "(no output)",
          0,
          0,
        );
      }

      const mdTheme = getMarkdownTheme();

      const renderDisplayItems = (items: DisplayItem[], limit?: number) => {
        const toShow = limit ? items.slice(-limit) : items;
        const skipped =
          limit && items.length > limit ? items.length - limit : 0;
        let text = "";
        if (skipped > 0)
          text += theme.fg("muted", `... ${skipped} earlier items\n`);
        for (const item of toShow) {
          if (item.type === "text") {
            const preview = expanded
              ? item.text
              : item.text.split("\n").slice(0, 3).join("\n");
            text += `${theme.fg("toolOutput", preview)}\n`;
          } else {
            text += `${theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme))}\n`;
          }
        }
        return text.trimEnd();
      };

      if (details.mode === "single" && details.results.length === 1) {
        const r = details.results[0];
        const isError = r.exitCode !== -1 && isFailedResult(r);
        const icon =
          r.exitCode === -1
            ? theme.fg("warning", "…")
            : isError
              ? theme.fg("error", "✗")
              : theme.fg("success", "✓");
        const displayItems = getDisplayItems(r.messages);
        const finalOutput = getFinalOutput(r.messages);

        if (expanded) {
          const container = new Container();
          let header = `${icon} ${theme.fg("toolTitle", theme.bold(r.agent))}${theme.fg("muted", ` (${r.agentSource})`)}`;
          if (isError && r.stopReason)
            header += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
          container.addChild(new Text(header, 0, 0));
          if (isError && r.errorMessage)
            container.addChild(
              new Text(theme.fg("error", `Error: ${r.errorMessage}`), 0, 0),
            );
          container.addChild(new Spacer(1));
          container.addChild(new Text(theme.fg("muted", "─── Task ───"), 0, 0));
          container.addChild(new Text(theme.fg("dim", r.task), 0, 0));
          container.addChild(new Spacer(1));
          container.addChild(
            new Text(theme.fg("muted", "─── Output ───"), 0, 0),
          );
          if (displayItems.length === 0 && !finalOutput) {
            container.addChild(
              new Text(theme.fg("muted", "(no output)"), 0, 0),
            );
          } else {
            for (const item of displayItems) {
              if (item.type === "toolCall")
                container.addChild(
                  new Text(
                    theme.fg("muted", "→ ") +
                      formatToolCall(
                        item.name,
                        item.args,
                        theme.fg.bind(theme),
                      ),
                    0,
                    0,
                  ),
                );
            }
            if (finalOutput) {
              container.addChild(new Spacer(1));
              container.addChild(
                new Markdown(finalOutput.trim(), 0, 0, mdTheme),
              );
            }
          }
          const usageStr = formatUsageStats(r.usage, r.model);
          if (usageStr) {
            container.addChild(new Spacer(1));
            container.addChild(new Text(theme.fg("dim", usageStr), 0, 0));
          }
          return container;
        }

        let text = `${icon} ${theme.fg("toolTitle", theme.bold(r.agent))}${theme.fg("muted", ` (${r.agentSource})`)}`;
        if (isError && r.stopReason)
          text += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
        if (isError && r.errorMessage)
          text += `\n${theme.fg("error", `Error: ${r.errorMessage}`)}`;
        else if (displayItems.length === 0)
          text += `\n${theme.fg("muted", "(no output)")}`;
        else {
          text += `\n${renderDisplayItems(displayItems, COLLAPSED_ITEM_COUNT)}`;
          if (displayItems.length > COLLAPSED_ITEM_COUNT)
            text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
        }
        const usageStr = formatUsageStats(r.usage, r.model);
        if (usageStr) text += `\n${theme.fg("dim", usageStr)}`;
        return new Text(text, 0, 0);
      }

      const aggregateUsage = (results: SingleResult[]) => {
        const total = {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          cost: 0,
          turns: 0,
        };
        for (const r of results) {
          total.input += r.usage.input;
          total.output += r.usage.output;
          total.cacheRead += r.usage.cacheRead;
          total.cacheWrite += r.usage.cacheWrite;
          total.cost += r.usage.cost;
          total.turns += r.usage.turns;
        }
        return total;
      };

      if (details.mode === "chain") {
        const successCount = details.results.filter(
          (r) => r.exitCode !== -1 && !isFailedResult(r),
        ).length;
        const icon = details.results.some((r) => r.exitCode === -1)
          ? theme.fg("warning", "…")
          : successCount === details.results.length
            ? theme.fg("success", "✓")
            : theme.fg("error", "✗");

        if (expanded) {
          const container = new Container();
          container.addChild(
            new Text(
              icon +
                " " +
                theme.fg("toolTitle", theme.bold("chain ")) +
                theme.fg(
                  "accent",
                  `${successCount}/${details.results.length} steps`,
                ),
              0,
              0,
            ),
          );

          for (const r of details.results) {
            const rIcon =
              r.exitCode === -1
                ? theme.fg("warning", "…")
                : !isFailedResult(r)
                  ? theme.fg("success", "✓")
                  : theme.fg("error", "✗");
            const displayItems = getDisplayItems(r.messages);
            const finalOutput = getFinalOutput(r.messages);

            container.addChild(new Spacer(1));
            container.addChild(
              new Text(
                `${theme.fg("muted", `─── Step ${r.step}: `) + theme.fg("accent", r.agent)} ${rIcon}`,
                0,
                0,
              ),
            );
            container.addChild(
              new Text(
                theme.fg("muted", "Task: ") + theme.fg("dim", r.task),
                0,
                0,
              ),
            );

            // Show tool calls
            for (const item of displayItems) {
              if (item.type === "toolCall") {
                container.addChild(
                  new Text(
                    theme.fg("muted", "→ ") +
                      formatToolCall(
                        item.name,
                        item.args,
                        theme.fg.bind(theme),
                      ),
                    0,
                    0,
                  ),
                );
              }
            }

            // Show final output as markdown
            if (finalOutput) {
              container.addChild(new Spacer(1));
              container.addChild(
                new Markdown(finalOutput.trim(), 0, 0, mdTheme),
              );
            }

            const stepUsage = formatUsageStats(r.usage, r.model);
            if (stepUsage)
              container.addChild(new Text(theme.fg("dim", stepUsage), 0, 0));
          }

          const usageStr = formatUsageStats(aggregateUsage(details.results));
          if (usageStr) {
            container.addChild(new Spacer(1));
            container.addChild(
              new Text(theme.fg("dim", `Total: ${usageStr}`), 0, 0),
            );
          }
          return container;
        }

        // Collapsed view
        let text =
          icon +
          " " +
          theme.fg("toolTitle", theme.bold("chain ")) +
          theme.fg("accent", `${successCount}/${details.results.length} steps`);
        for (const r of details.results) {
          const rIcon =
            r.exitCode === -1
              ? theme.fg("warning", "…")
              : !isFailedResult(r)
                ? theme.fg("success", "✓")
                : theme.fg("error", "✗");
          const displayItems = getDisplayItems(r.messages);
          text += `\n\n${theme.fg("muted", `─── Step ${r.step}: `)}${theme.fg("accent", r.agent)} ${rIcon}`;
          if (displayItems.length === 0)
            text += `\n${theme.fg("muted", "(no output)")}`;
          else text += `\n${renderDisplayItems(displayItems, 5)}`;
        }
        const usageStr = formatUsageStats(aggregateUsage(details.results));
        if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
        text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
        return new Text(text, 0, 0);
      }

      if (details.mode === "parallel") {
        const running = details.results.filter((r) => r.exitCode === -1).length;
        const successCount = details.results.filter(
          (r) => r.exitCode !== -1 && !isFailedResult(r),
        ).length;
        const failCount = details.results.filter(
          (r) => r.exitCode !== -1 && isFailedResult(r),
        ).length;
        const isRunning = running > 0;
        const icon = isRunning
          ? theme.fg("warning", "⏳")
          : failCount > 0
            ? theme.fg("warning", "◐")
            : theme.fg("success", "✓");
        const status = isRunning
          ? `${successCount + failCount}/${details.results.length} done, ${running} running`
          : `${successCount}/${details.results.length} tasks`;

        if (expanded && !isRunning) {
          const container = new Container();
          container.addChild(
            new Text(
              `${icon} ${theme.fg("toolTitle", theme.bold("parallel "))}${theme.fg("accent", status)}`,
              0,
              0,
            ),
          );

          for (const r of details.results) {
            const rIcon = isFailedResult(r)
              ? theme.fg("error", "✗")
              : theme.fg("success", "✓");
            const displayItems = getDisplayItems(r.messages);
            const finalOutput = getFinalOutput(r.messages);

            container.addChild(new Spacer(1));
            container.addChild(
              new Text(
                `${theme.fg("muted", "─── ") + theme.fg("accent", r.agent)} ${rIcon}`,
                0,
                0,
              ),
            );
            container.addChild(
              new Text(
                theme.fg("muted", "Task: ") + theme.fg("dim", r.task),
                0,
                0,
              ),
            );

            // Show tool calls
            for (const item of displayItems) {
              if (item.type === "toolCall") {
                container.addChild(
                  new Text(
                    theme.fg("muted", "→ ") +
                      formatToolCall(
                        item.name,
                        item.args,
                        theme.fg.bind(theme),
                      ),
                    0,
                    0,
                  ),
                );
              }
            }

            // Show final output as markdown
            if (finalOutput) {
              container.addChild(new Spacer(1));
              container.addChild(
                new Markdown(finalOutput.trim(), 0, 0, mdTheme),
              );
            }

            const taskUsage = formatUsageStats(r.usage, r.model);
            if (taskUsage)
              container.addChild(new Text(theme.fg("dim", taskUsage), 0, 0));
          }

          const usageStr = formatUsageStats(aggregateUsage(details.results));
          if (usageStr) {
            container.addChild(new Spacer(1));
            container.addChild(
              new Text(theme.fg("dim", `Total: ${usageStr}`), 0, 0),
            );
          }
          return container;
        }

        // Collapsed view (or still running)
        let text = `${icon} ${theme.fg("toolTitle", theme.bold("parallel "))}${theme.fg("accent", status)}`;
        for (const r of details.results) {
          const rIcon =
            r.exitCode === -1
              ? theme.fg("warning", "⏳")
              : isFailedResult(r)
                ? theme.fg("error", "✗")
                : theme.fg("success", "✓");
          const displayItems = getDisplayItems(r.messages);
          text += `\n\n${theme.fg("muted", "─── ")}${theme.fg("accent", r.agent)} ${rIcon}`;
          if (displayItems.length === 0)
            text += `\n${theme.fg("muted", r.exitCode === -1 ? "(running...)" : "(no output)")}`;
          else text += `\n${renderDisplayItems(displayItems, 5)}`;
        }
        if (!isRunning) {
          const usageStr = formatUsageStats(aggregateUsage(details.results));
          if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
        }
        if (!expanded) text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
        return new Text(text, 0, 0);
      }

      const text = result.content[0];
      return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
    },
  });
}
