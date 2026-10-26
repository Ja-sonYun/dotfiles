// Vendored from Pi v1.1.0 under the MIT license; see LICENSE.
// https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/examples/extensions/subagent/index.ts

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type {
  AgentToolResult,
  ThinkingLevel,
} from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
import { withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import { connectPermissions, type PermissionBridge } from "./permissions.ts";
import type { AgentConfig } from "./agents.ts";
import {
  getFinalOutput,
  type SingleResult,
  type SubagentDetails,
} from "./runs.ts";

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

export type OnUpdateCallback = (
  partial: AgentToolResult<SubagentDetails>,
) => void;

export interface DispatchDefaults {
  model?: string;
  thinkingLevel?: ThinkingLevel;
  permissions: (
    agent: AgentConfig,
    task: string,
    cwd: string,
  ) => PermissionBridge | undefined;
}

export async function runSingleAgent(
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
