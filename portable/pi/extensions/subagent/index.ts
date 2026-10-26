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

import type { PermissionBridge } from "./permissions.ts";
import * as path from "node:path";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import { StringEnum } from "@earendil-works/pi-ai";
import {
  CONFIG_DIR_NAME,
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  getMarkdownTheme,
  keyHint,
} from "@earendil-works/pi-coding-agent";
import {
  Markdown,
  Text,
  stripTerminalSequences,
  truncateToWidth,
} from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { type AgentConfig, type AgentScope, discoverAgents } from "./agents.ts";

import {
  runSingleAgent,
  type DispatchDefaults,
  type OnUpdateCallback,
} from "./runner.ts";
import {
  getFinalOutput,
  getResultOutput,
  isFailedResult,
  resultCounts,
  mapWithConcurrencyLimit,
  type SingleResult,
  type SubagentDetails,
  type BackgroundRun,
} from "./runs.ts";
import {
  createRenderers,
  stateColor,
  diagnosticLine,
  truncateParallelOutput,
} from "./render.ts";

const MAX_PARALLEL_TASKS = 8;
const MAX_CONCURRENCY = 4;

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

export const SubagentParams = Type.Object({
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

    ...createRenderers(pi),
  });
}
