import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
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
  parser: string;
  search: string;
  evaluator: string[];
  summaries: SummaryConfiguration | null;
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

function parentPermission(call: Call): Promise<Outcome> {
  return new Promise((resolve) => {
    if (!process.send || !process.connected) {
      resolve({ block: true, reason: "Parent permission channel unavailable" });
      return;
    }
    const id = randomUUID();
    const finish = (result: Outcome) => {
      clearTimeout(timeout);
      process.removeListener("message", receive);
      process.removeListener("disconnect", disconnected);
      resolve(result);
    };
    const receive = (message: any) => {
      if (message?.type !== "pi:permission:result" || message.id !== id) return;
      finish(
        message.allow === true
          ? undefined
          : {
              block: true,
              reason: message.reason || "Parent denied execution",
            },
      );
    };
    const disconnected = () =>
      finish({ block: true, reason: "Parent permission channel closed" });
    const timeout = setTimeout(
      () => finish({ block: true, reason: "Parent approval timed out" }),
      10 * 60 * 1000,
    );
    process.on("message", receive);
    process.once("disconnect", disconnected);
    process.send({ type: "pi:permission:check", id, call }, (error) => {
      if (error) disconnected();
    });
  });
}

export default function (pi: ExtensionAPI): void {
  if (process.env.PI_PERMISSION_CHILD === "1") {
    pi.on("tool_call", (event, ctx) => {
      normalizeFileCall(event, ctx.cwd);
      return parentPermission(event);
    });
    pi.on("session_start", () => {
      if (process.env.PI_PERMISSION_MODE === "plan") {
        const config: Configuration = JSON.parse(
          readFileSync(process.env.PI_PERMISSIONS_CONFIG!, "utf8"),
        );
        const allowed = readonlyTools(config.policy);
        pi.setActiveTools(
          pi.getActiveTools().filter((name) => allowed.includes(name)),
        );
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
  let configuration = "";
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
      const serialized = readFileSync(
        process.env.PI_PERMISSIONS_CONFIG!,
        "utf8",
      );
      if (configuration !== serialized) {
        if (configuration) cancelBackground();
        configuration = serialized;
        session.reset();
      }
      const config: Configuration = JSON.parse(serialized);
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
      const result = await (background?.session ?? session).check(
        call,
        actor,
        request,
        fingerprint(config),
        assessment,
        async (cancellation) => {
          const result = (await runJson(
            config.evaluator,
            {
              client: "pi",
              cwd: actor.cwd,
              tool_name: call.toolName,
              tool_input: call.input,
              additionalRules: permissionRules,
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
                proposal_context:
                  approval?.proposalContext ?? proposalContext(),
              } satisfies PermissionRuleContext,
            },
            actor.cwd,
            cancellation,
          )) as RuleResult;
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
    const actor: Actor = {
      cwd: canonical(absolute(message.cwd, approval.actor.cwd)),
      name: message.name,
      mode: message.mode ?? "default",
      task: message.task,
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
    });
  });
}
