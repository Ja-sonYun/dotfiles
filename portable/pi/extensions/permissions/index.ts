import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { analyzeBash } from "./bash.ts";
import { showPermission } from "./permission-ui.ts";
import { toolSummaries, type SummaryConfiguration } from "./tool-summaries.ts";
import {
  absolute,
  assess,
  assessSearch,
  canonical,
  normalizeFileCall,
  readonlyTools,
  strongest,
  type Actor,
  type Call,
  type Policy,
} from "./policy.ts";
import { runJson } from "./process.ts";
import { permissionRules, type PermissionRuleContext } from "./rules.ts";
import {
  fingerprint,
  PermissionSession,
  type Approve,
  type Outcome,
  type RuleResult,
} from "./session.ts";

interface Configuration {
  policy: Policy;
  configuredRules: Record<string, unknown>;
  parser: string;
  search: string;
  evaluator: string[];
  summaries: SummaryConfiguration | null;
}

async function loadConfig(
  cwd: string,
  signal?: AbortSignal,
): Promise<{ source: string | null; config: Configuration }> {
  return (await runJson(
    ["pi-permissions-evaluator", "config"],
    {
      path: process.env.PI_PERMISSIONS_CONFIG ?? null,
      configDir: fileURLToPath(new URL("../../config/", import.meta.url)),
    },
    cwd,
    signal ?? AbortSignal.timeout(35000),
  )) as { source: string | null; config: Configuration };
}

interface DispatchApproval {
  call: Call;
  actor: Actor;
  request: string;
  version: number;
  proposalContext: string;
  unattributed: boolean;
  background?: {
    active: boolean;
    signal: AbortSignal;
    cancel: () => void;
    session: PermissionSession;
  };
}

const ruleTools = ["rules_check", "rules_request_approval"];
interface ParentResponse {
  allow: boolean;
  reason?: string;
  result?: Record<string, unknown>;
}

function parentRequest(
  call: Call,
  operation: "check" | "rules" = "check",
  signal?: AbortSignal,
): Promise<ParentResponse> {
  return new Promise((resolve) => {
    if (!process.send || !process.connected) {
      resolve({
        allow: false,
        reason: "Parent permission channel unavailable",
      });
      return;
    }
    const id = randomUUID();
    const finish = (result: ParentResponse) => {
      if (!result.allow && process.connected)
        process.send?.({ type: "pi:permission:cancel", id }, () => {});
      clearTimeout(timeout);
      process.removeListener("message", receive);
      process.removeListener("disconnect", disconnected);
      signal?.removeEventListener("abort", disconnected);
      resolve(result);
    };
    const receive = (message: any) => {
      if (message?.type !== "pi:permission:result" || message.id !== id) return;
      finish({
        allow: message.allow === true,
        reason: message.reason,
        result: message.result,
      });
    };
    const disconnected = () =>
      finish({
        allow: false,
        reason: "Parent permission channel closed or cancelled",
      });
    const timeout = setTimeout(
      () => finish({ allow: false, reason: "Parent approval timed out" }),
      10 * 60 * 1000,
    );
    process.on("message", receive);
    process.once("disconnect", disconnected);
    signal?.addEventListener("abort", disconnected, { once: true });
    if (signal?.aborted) {
      disconnected();
      return;
    }
    process.send({ type: `pi:permission:${operation}`, id, call }, (error) => {
      if (error) disconnected();
    });
  });
}

export default function (pi: ExtensionAPI): void {
  let executeRuleTool: (
    call: Call,
    signal: AbortSignal | undefined,
    ctx: ExtensionContext,
  ) => Promise<Record<string, unknown>> = async (call, signal) => {
    const response = await parentRequest(call, "rules", signal);
    return (
      response.result ?? { status: "unavailable", reason: response.reason }
    );
  };
  const runControl = async (
    toolName: string,
    input: Record<string, unknown>,
    signal: AbortSignal | undefined,
    ctx: ExtensionContext,
  ) => {
    const result = await executeRuleTool({ toolName, input }, signal, ctx);
    return {
      content: [{ type: "text" as const, text: JSON.stringify(result) }],
      details: result,
    };
  };
  pi.registerTool({
    name: "rules_check",
    label: "Check task rules",
    description:
      "Check a plan or response against task rules. Provide the user request, approval evidence, and full proposed text. A request ID can be sent to rules_request_approval; user_approved is an exception, not execution permission.",
    parameters: Type.Object({ text: Type.String() }),
    execute: (_id, params, signal, _update, ctx) =>
      runControl("rules_check", params, signal, ctx),
  });
  pi.registerTool({
    name: "rules_request_approval",
    label: "Request rule exception",
    description:
      "Ask the user to approve one stored rule request. Calling this tool is not approval. Only an approved result permits retrying the exact request once; never answer the user confirmation yourself.",
    parameters: Type.Object({ request_id: Type.String() }),
    execute: (_id, params, signal, _update, ctx) =>
      runControl("rules_request_approval", params, signal, ctx),
  });
  if (process.env.PI_PERMISSION_CHILD === "1") {
    let configurationReady = process.env.PI_PERMISSION_MODE !== "plan";
    pi.on("tool_call", async (event, ctx) => {
      if (ruleTools.includes(event.toolName)) return;
      if (!configurationReady) {
        return { block: true, reason: "Permission configuration unavailable" };
      }
      normalizeFileCall(event, ctx.cwd);
      const response = await parentRequest(event);
      return response.allow
        ? undefined
        : {
            block: true as const,
            reason: response.reason ?? "Parent denied execution",
          };
    });
    pi.on("session_start", async (_event, ctx) => {
      if (process.env.PI_PERMISSION_MODE === "plan") {
        configurationReady = false;
        try {
          const { config } = await loadConfig(ctx.cwd);
          const allowed = [...readonlyTools(config.policy), ...ruleTools];
          pi.setActiveTools(
            pi.getActiveTools().filter((name) => allowed.includes(name)),
          );
          configurationReady = true;
        } catch (error) {
          pi.setActiveTools([]);
          throw error;
        }
      }
    });
    pi.on("session_shutdown", () => {
      if (process.connected) process.disconnect();
    });
    return;
  }

  const session = new PermissionSession();
  const summaries = toolSummaries(pi);
  let requests: string[] = [];
  let inputs: { text: string; source: string }[] = [];
  let immediate: { text: string; source: string } | undefined;
  let starting: { prompt: string; input: typeof immediate } | undefined;
  let unattributed = false;
  let context: ExtensionContext | undefined;
  let configuration: string | null | undefined;
  let contextVersion = 0;
  const dispatchApprovals = new Map<string, DispatchApproval>();
  let approvalQueue: Promise<unknown> = Promise.resolve();

  const proposalContext = () =>
    (context?.sessionManager?.getBranch() ?? [])
      .flatMap((entry) =>
        entry.type === "message" && entry.message.role === "assistant"
          ? entry.message.content
              .filter((part) => part.type === "text")
              .map((part) => part.text)
          : [],
      )
      .slice(-4)
      .join("\n\n")
      .slice(-16000);

  const cancelBackground = () => {
    for (const approval of dispatchApprovals.values()) {
      if (!approval.background) continue;
      approval.background.active = false;
      approval.background.session.reset();
      approval.background.cancel();
    }
  };

  const presentApproval: Approve = async (approval, signal) => {
    if (!context?.hasUI) return "deny";
    const options = [
      "Deny",
      "Allow once",
      ...(approval.sessionAllowed
        ? ["Allow this exact scope for this session"]
        : []),
    ];
    const choice = await showPermission(
      {
        options,
        call: approval.call,
        actor: approval.actor,
        reasons: approval.reasons,
        signal,
        context,
      },
      { text: approval.summary },
    );
    return choice === "Allow once"
      ? "once"
      : choice === "Allow this exact scope for this session"
        ? "session"
        : "deny";
  };

  const approve: Approve = (approval, signal) => {
    const pending = approvalQueue.then(() =>
      signal.aborted ? ("deny" as const) : presentApproval(approval, signal),
    );
    approvalQueue = pending.catch(() => {});
    return pending;
  };

  async function check(
    call: Call,
    actor: Actor,
    request: string,
    signal?: AbortSignal,
    approval?: DispatchApproval,
  ): Promise<Outcome> {
    const version = approval?.version ?? contextVersion;
    const background = approval?.background;
    const current = () =>
      version === contextVersion &&
      (background
        ? background.active && !background.signal.aborted
        : request === JSON.stringify(requests));
    try {
      const { source: serialized, config } = await loadConfig(
        actor.cwd,
        signal,
      );
      if (configuration !== serialized) {
        if (configuration !== undefined) cancelBackground();
        configuration = serialized;
        session.reset();
      }
      const summaryContext = context;
      const checkSummary = Boolean(config.summaries && summaryContext?.hasUI);
      let summary: string | undefined;
      const shell =
        call.toolName === "bash" && typeof call.input.command === "string"
          ? await analyzeBash(call.input.command, config.parser)
          : undefined;
      const assessment = assess(
        config.policy,
        call,
        actor,
        shell,
        context?.cwd,
      );
      if (call.toolName === "grep" && assessment.decision !== "deny") {
        const search = await assessSearch(
          config.policy,
          call,
          actor,
          config.search,
          context?.cwd,
        );
        assessment.decision = strongest([assessment.decision, search.decision]);
        assessment.reasons.push(...search.reasons);
        assessment.projectRead = Boolean(
          assessment.projectRead && search.projectRead,
        );
      }
      if (!current())
        return { block: true, reason: "Permission context changed" };
      const evaluationInput = {
        client: "pi",
        cwd: actor.cwd,
        tool_name: call.toolName,
        tool_input: call.input,
        additionalRules: permissionRules,
        configuredRules: config.configuredRules,
        check_summary: checkSummary,
        context: {
          user_request: request,
          actor: actor.name,
          permission_mode: actor.mode,
          delegated_task: actor.task,
          analysis: shell ?? null,
          approvals: approval
            ? [
                {
                  call: approval.call,
                  actor: approval.actor,
                  request: approval.request,
                },
              ]
            : [],
          proposal_context: approval?.proposalContext ?? proposalContext(),
        } satisfies PermissionRuleContext,
      };
      const snapshot = async (
        cancellation: AbortSignal,
      ): Promise<RuleResult> => {
        const latest = await loadConfig(actor.cwd, cancellation);
        if (!current() || fingerprint(latest.config) !== fingerprint(config)) {
          throw new Error("Permission context changed");
        }
        return (await runJson(
          [...config.evaluator.slice(0, -1), "state"],
          evaluationInput,
          actor.cwd,
          cancellation,
        )) as RuleResult;
      };
      const result = await (background?.session ?? session).check(
        call,
        actor,
        request,
        fingerprint(config),
        assessment,
        async (cancellation) => {
          let result: RuleResult;
          try {
            result = (await runJson(
              config.evaluator,
              evaluationInput,
              actor.cwd,
              cancellation,
            )) as RuleResult;
          } catch {
            result = {
              ...(await snapshot(cancellation)),
              errors: ["Rule evaluation unavailable"],
              results: [],
            };
          }
          if (!result.file_state) {
            const state = await snapshot(cancellation);
            result = {
              ...result,
              fingerprint: state.fingerprint,
              file_state: state.file_state,
            };
          }
          if (approval?.unattributed ?? unattributed) {
            result.errors.push(
              "The consumed user message could not be attributed; inspect this call manually",
            );
          }
          return result;
        },
        (approval, cancellation) =>
          approve({ ...approval, summary }, cancellation),
        signal,
        async (rules, cancellation) => {
          if (!checkSummary) return;
          if (typeof rules.needs_summary !== "boolean") {
            throw new Error("Summary decision unavailable");
          }
          if (config.summaries && summaryContext) {
            summary = await summaries.prepare(
              call,
              config.summaries,
              summaryContext,
              cancellation,
            );
          }
        },
        snapshot,
      );
      if (!current())
        return { block: true, reason: "Permission context changed" };
      return result;
    } catch {
      return {
        block: true,
        reason: "Permission configuration or path inspection failed",
      };
    }
  }

  async function ruleTool(
    call: Call,
    actor: Actor,
    request: string,
    signal?: AbortSignal,
    approval?: DispatchApproval,
  ): Promise<Record<string, unknown>> {
    if (!ruleTools.includes(call.toolName))
      return { status: "unavailable", reason: "Unknown rule tool" };
    const version = approval?.version ?? contextVersion;
    const current = () =>
      version === contextVersion &&
      (approval?.background
        ? approval.background.active && !approval.background.signal.aborted
        : request === JSON.stringify(requests));
    const cancellation = signal ?? new AbortController().signal;
    try {
      const { source, config } = await loadConfig(actor.cwd, cancellation);
      if (configuration !== source) {
        if (configuration !== undefined) cancelBackground();
        configuration = source;
        session.reset();
      }
      if (!current())
        return { status: "unavailable", reason: "Permission context changed" };
      const selected = approval?.background?.session ?? session;
      if (call.toolName === "rules_request_approval") {
        if (typeof call.input.request_id !== "string")
          return { status: "unavailable", reason: "Missing request ID" };
        return await selected.requestRuleApproval(
          call.input.request_id,
          actor,
          request,
          fingerprint(config),
          approve,
          cancellation,
        );
      }
      if (typeof call.input.text !== "string")
        return { status: "incomplete", errors: ["Missing task text"] };
      const input = {
        client: "pi",
        target: "task",
        cwd: actor.cwd,
        tool_name: call.toolName,
        tool_input: call.input,
        configuredRules: config.configuredRules,
        context: {
          user_request: request,
          actor: actor.name,
          permission_mode: actor.mode,
          delegated_task: actor.task,
          proposal_context: approval?.proposalContext ?? proposalContext(),
        },
      };
      const snapshot = async (abort: AbortSignal): Promise<RuleResult> => {
        const latest = await loadConfig(actor.cwd, abort);
        if (!current() || fingerprint(latest.config) !== fingerprint(config))
          throw new Error("Permission context changed");
        return (await runJson(
          [...config.evaluator.slice(0, -1), "state"],
          input,
          actor.cwd,
          abort,
        )) as RuleResult;
      };
      let rules: RuleResult;
      try {
        rules = (await runJson(
          config.evaluator,
          input,
          actor.cwd,
          cancellation,
        )) as RuleResult;
      } catch {
        rules = {
          ...(await snapshot(cancellation)),
          results: [],
          errors: ["Task rule evaluation unavailable"],
          status: "incomplete",
        };
      }
      if (!current())
        return { status: "incomplete", errors: ["Permission context changed"] };
      if (!rules.file_state) {
        const state = await snapshot(cancellation);
        rules = {
          ...rules,
          fingerprint: state.fingerprint,
          file_state: state.file_state,
        };
      }
      return await selected.checkTask(
        call,
        actor,
        request,
        fingerprint(config),
        rules,
        snapshot,
        cancellation,
      );
    } catch {
      return {
        status: "unavailable",
        reason: "Rule configuration or request state unavailable",
      };
    }
  }

  executeRuleTool = (call, signal, ctx) => {
    context = ctx;
    return ruleTool(
      call,
      { cwd: canonical(ctx.cwd), name: "main", mode: "default", task: "" },
      JSON.stringify(requests),
      signal,
    );
  };

  const resetContext = (_event: unknown, ctx: ExtensionContext) => {
    cancelBackground();
    context = ctx;
    contextVersion++;
    session.reset();
    requests = [];
    inputs = [];
    immediate = undefined;
    starting = undefined;
    unattributed = true;
    dispatchApprovals.clear();
  };
  pi.on("session_start", resetContext);
  pi.on("session_tree", resetContext);
  pi.on("session_shutdown", resetContext);
  pi.on("input", (event, ctx) => {
    if (!ctx.hasPendingMessages()) inputs = [];
    const input = { text: event.text, source: event.source };
    if (event.streamingBehavior) inputs.push(input);
    else immediate = input;
  });
  pi.on("before_agent_start", (event, ctx) => {
    context = ctx;
    starting = { prompt: event.prompt, input: immediate };
    immediate = undefined;
  });
  pi.on("message_start", (event, ctx) => {
    if (event.message.role !== "user") return;
    context = ctx;
    const text =
      typeof event.message.content === "string"
        ? event.message.content
        : event.message.content
            .filter((part) => part.type === "text")
            .map((part) => part.text)
            .join("\n");
    // Pi exposes input sources before expansion, but not on consumed messages.
    // https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/src/core/agent-session.ts
    let input: typeof immediate;
    if (
      starting &&
      (text === starting.prompt || text.startsWith(`${starting.prompt}\n\n`))
    ) {
      input = starting.input;
    } else {
      const matches = inputs.filter((candidate) => candidate.text === text);
      if (new Set(matches.map((candidate) => candidate.source)).size === 1) {
        input = matches[0];
        inputs.splice(inputs.indexOf(input), 1);
      }
    }
    starting = undefined;
    if (!ctx.hasPendingMessages()) inputs = [];
    session.reset();
    if (input?.source === "extension") return;
    unattributed = !input;
    if (input) requests.push(input.text);
  });
  pi.on("tool_call", async (event, ctx) => {
    context = ctx;
    if (ruleTools.includes(event.toolName)) return;
    normalizeFileCall(event, ctx.cwd);
    const call = structuredClone(event);
    const actor: Actor = {
      cwd: canonical(ctx.cwd),
      name: "main",
      mode: "default",
      task: "",
    };
    const request = JSON.stringify(requests);
    const version = contextVersion;
    const proposal = proposalContext();
    const unknownInput = unattributed;
    const result = await check(call, actor, request);
    if (version !== contextVersion || request !== JSON.stringify(requests))
      return { block: true, reason: "Permission context changed" };
    if (
      !result &&
      event.toolName === "subagent" &&
      [undefined, "run"].includes(event.input.action as string | undefined)
    ) {
      dispatchApprovals.set(event.toolCallId, {
        call,
        actor,
        request,
        version,
        proposalContext: proposal,
        unattributed: unknownInput,
      });
    }
    return result;
  });
  pi.on("tool_result", (event) => {
    if (!dispatchApprovals.get(event.toolCallId)?.background?.active) {
      dispatchApprovals.delete(event.toolCallId);
    }
  });

  // Keep later parent messages from replacing an active task's approved scope.
  // The caller releases this scope only after its children have stopped and been reaped.
  pi.events.on("permissions:background", (message: any) => {
    const approval = dispatchApprovals.get(message?.dispatchId);
    if (
      !approval ||
      approval.background ||
      approval.version !== contextVersion ||
      approval.request !== JSON.stringify(requests) ||
      approval.call.input.background === false ||
      !(message.signal instanceof AbortSignal) ||
      message.signal.aborted ||
      typeof message.cancel !== "function" ||
      typeof message.reply !== "function"
    )
      return;

    approval.background = {
      active: true,
      signal: message.signal,
      cancel: message.cancel,
      session: new PermissionSession(),
    };
    message.reply(() => {
      approval.background!.active = false;
      approval.background!.session.reset();
      if (dispatchApprovals.get(message.dispatchId) === approval) {
        dispatchApprovals.delete(message.dispatchId);
      }
    });
  });

  // This event is the public subagent integration contract; the parent owns identity and mode.
  pi.events.on("permissions:child", (message: any) => {
    if (!context || typeof message?.reply !== "function") return;
    if (![undefined, "default", "plan"].includes(message.mode)) return;
    const approval = dispatchApprovals.get(message.dispatchId);
    if (!approval || approval.version !== contextVersion) return;
    const actor: Actor & { owner: string } = {
      cwd: canonical(absolute(message.cwd, approval.actor.cwd)),
      name: message.name,
      mode: message.mode ?? "default",
      task: message.task,
      owner: randomUUID(),
    };
    const request = approval.request;
    const version = approval.version;
    message.reply({
      extension: fileURLToPath(import.meta.url),
      mode: actor.mode,
      check: (call: Call, signal: AbortSignal) => {
        if (
          version !== contextVersion ||
          (approval.background
            ? !approval.background.active || approval.background.signal.aborted
            : request !== JSON.stringify(requests))
        )
          return Promise.resolve({
            block: true,
            reason: "Parent request changed; dispatch the agent again",
          });
        return check(
          call,
          actor,
          request,
          approval.background
            ? AbortSignal.any([signal, approval.background.signal])
            : signal,
          approval,
        );
      },
      rules: (call: Call, signal: AbortSignal) =>
        ruleTool(
          call,
          actor,
          request,
          approval.background
            ? AbortSignal.any([signal, approval.background.signal])
            : signal,
          approval,
        ),
    });
  });
}
