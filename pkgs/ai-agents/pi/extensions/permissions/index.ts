import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { analyzeBash } from "./bash.ts";
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
  let requests: string[] = [];
  let inputs: { text: string; source: string }[] = [];
  let immediate: { text: string; source: string } | undefined;
  let starting: { prompt: string; input: typeof immediate } | undefined;
  let unattributed = false;
  let context: ExtensionContext | undefined;
  let configuration = "";
  let contextVersion = 0;
  const dispatchApprovals = new Map<
    string,
    { call: Call; actor: Actor; request: string }
  >();

  const approve: Approve = async (approval, signal) => {
    if (!context?.hasUI) return "deny";
    const title = [
      `Permission: ${approval.actor.name} (${approval.actor.mode})`,
      `Working directory: ${approval.actor.cwd}`,
      `${approval.call.toolName} ${JSON.stringify(approval.call.input)}`,
      ...approval.reasons,
    ].join("\n");
    const options = [
      "Deny",
      "Allow once",
      ...(approval.sessionAllowed
        ? ["Allow this exact scope for this session"]
        : []),
    ];
    let presentation: Promise<string | undefined> | undefined;
    // Let a display extension present this request while permissions owns the decision.
    pi.events.emit("permissions:approval", {
      title,
      options,
      call: approval.call,
      actor: approval.actor,
      reasons: approval.reasons,
      signal,
      context,
      reply: (choice: Promise<string | undefined>) => {
        presentation = choice;
      },
    });
    const choice = await (presentation ??
      context.ui.select(title, options, { signal }));
    return choice === "Allow once"
      ? "once"
      : choice === "Allow this exact scope for this session"
        ? "session"
        : "deny";
  };

  async function check(
    call: Call,
    actor: Actor,
    request: string,
    signal?: AbortSignal,
    approvals: { call: Call; actor: Actor; request: string }[] = [],
  ): Promise<Outcome> {
    const version = contextVersion;
    try {
      const serialized = readFileSync(
        process.env.PI_PERMISSIONS_CONFIG!,
        "utf8",
      );
      if (configuration !== serialized) {
        configuration = serialized;
        session.reset();
      }
      const config: Configuration = JSON.parse(serialized);
      const shell =
        call.toolName === "bash" && typeof call.input.command === "string"
          ? await analyzeBash(call.input.command, config.parser)
          : undefined;
      const assessment = assess(config.policy, call, actor, shell);
      if (call.toolName === "grep" && assessment.decision !== "deny") {
        const search = await assessSearch(
          config.policy,
          call,
          actor,
          config.search,
        );
        assessment.decision = strongest([assessment.decision, search.decision]);
        assessment.reasons.push(...search.reasons);
      }
      if (version !== contextVersion || request !== JSON.stringify(requests))
        return { block: true, reason: "Permission context changed" };
      const result = await session.check(
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
              context: {
                user_request: request,
                actor: actor.name,
                permission_mode: actor.mode,
                delegated_task: actor.task,
                analysis: shell ?? null,
                approvals,
                proposal_context: (context?.sessionManager?.getBranch() ?? [])
                  .flatMap((entry) =>
                    entry.type === "message" &&
                    entry.message.role === "assistant"
                      ? entry.message.content
                          .filter((part) => part.type === "text")
                          .map((part) => part.text)
                      : [],
                  )
                  .slice(-4)
                  .join("\n\n")
                  .slice(-16000),
              } satisfies PermissionRuleContext,
            },
            actor.cwd,
            cancellation,
          )) as RuleResult;
          if (unattributed) {
            result.errors.push(
              "The consumed user message could not be attributed; inspect this call manually",
            );
          }
          return result;
        },
        approve,
        signal,
      );
      if (version !== contextVersion)
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
    const result = await check(call, actor, request);
    if (version !== contextVersion)
      return { block: true, reason: "Permission context changed" };
    if (!result && event.toolName === "subagent")
      dispatchApprovals.set(event.toolCallId, { call, actor, request });
    return result;
  });
  pi.on("tool_result", (event) => {
    dispatchApprovals.delete(event.toolCallId);
  });

  // This event is the public subagent integration contract; the parent owns identity and mode.
  pi.events.on("permissions:child", (message: any) => {
    if (!context || typeof message?.reply !== "function") return;
    if (![undefined, "default", "plan"].includes(message.mode)) return;
    const approval = dispatchApprovals.get(message.dispatchId);
    if (!approval) return;
    const actor: Actor = {
      cwd: canonical(absolute(message.cwd, context.cwd)),
      name: message.name,
      mode: message.mode ?? "default",
      task: message.task,
    };
    const request = JSON.stringify(requests);
    const version = contextVersion;
    message.reply({
      extension: fileURLToPath(import.meta.url),
      mode: actor.mode,
      check: (call: Call, signal: AbortSignal) => {
        if (version !== contextVersion || request !== JSON.stringify(requests))
          return Promise.resolve({
            block: true,
            reason: "Parent request changed; dispatch the agent again",
          });
        return check(call, actor, request, signal, [approval]);
      },
    });
  });
}
