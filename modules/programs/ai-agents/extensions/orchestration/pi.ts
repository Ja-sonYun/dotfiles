import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const parentStateKey = Symbol.for("dotfiles.pi.orchestration.parent");
const runtime: typeof globalThis & {
  [parentStateKey]?: {
    parentId: string | undefined;
  };
} = globalThis;

export default function (pi: ExtensionAPI) {
  pi.events.on("permissions:mcp-all-modes", (event: unknown) => {
    if (
      typeof event === "object" &&
      event !== null &&
      "servers" in event &&
      event.servers instanceof Set
    ) {
      event.servers.add("orchestration");
    }
  });
  const { parentId } = (runtime[parentStateKey] ??= {
    parentId: process.env.AGENT_HUB_CURRENT_ID,
  });
  let queue = Promise.resolve();
  let running = false;
  let outcome = "completed";
  let prompts = 0;
  let runId = "";
  let prompt = "";

  pi.registerMcpServer("orchestration", {
    exposure: "direct",
    command: "@command@",
    args: ["mcp"],
    env: { AI_AGENT_CLIENT: "pi" },
  });

  function publish(
    ctx: ExtensionContext,
    event: string,
    fields: Record<string, unknown> = {},
  ) {
    const payload = JSON.stringify({
      hook_event_name: event,
      reported_at: Date.now(),
      event_id: randomUUID(),
      run_id: runId,
      session_id: ctx.sessionManager.getSessionId(),
      session_title: ctx.sessionManager.getSessionName() ?? "",
      cwd: ctx.cwd,
      parent_agent_id: parentId,
      ...fields,
    });
    const env = { ...process.env, AI_AGENT_CLIENT: "Pi" };
    queue = queue
      .then(
        () =>
          new Promise<void>((resolve) => {
            const child = spawn("@command@", ["hook"], {
              env,
              detached: true,
              stdio: ["pipe", "ignore", "inherit"],
            });
            let finished = false;
            let closed = false;
            let cleaning = false;
            let groupGone = false;
            let killTimer: ReturnType<typeof setTimeout> | undefined;
            let cleanupTimer: ReturnType<typeof setTimeout> | undefined;
            let poll: ReturnType<typeof setInterval> | undefined;
            const signalGroup = (signal: NodeJS.Signals | 0): boolean => {
              if (!child.pid || groupGone) return false;
              try {
                process.kill(-child.pid, signal);
                return true;
              } catch (error) {
                if (!(
                  error instanceof Error &&
                  "code" in error &&
                  error.code === "ESRCH"
                )) {
                  console.error("AgentHub hook process group:", error);
                  return true;
                }
                groupGone = true;
                return false;
              }
            };
            const finish = () => {
              if (finished) return;
              finished = true;
              clearTimeout(timeout);
              clearTimeout(killTimer);
              clearTimeout(cleanupTimer);
              clearInterval(poll);
              child.stdin.destroy();
              child.unref();
              resolve();
            };
            const timeout = setTimeout(() => {
              cleaning = true;
              console.error("AgentHub hook timed out after 3 seconds");
              child.stdin.destroy();
              signalGroup("SIGTERM");
              killTimer = setTimeout(() => {
                if (signalGroup(0)) signalGroup("SIGKILL");
              }, 500);
              cleanupTimer = setTimeout(() => {
                if (signalGroup(0) || !closed) {
                  console.error("AgentHub hook cleanup exceeded 1 second");
                }
                finish();
              }, 1000);
            }, 3000);
            child.on("error", (error) => {
              console.error("AgentHub hook:", error);
              if (!child.pid) finish();
            });
            child.on("close", (code, signal) => {
              closed = true;
              if (!cleaning && (code !== 0 || signal !== null)) {
                console.error("AgentHub hook failed:", code, signal);
              }
              if (finished) return;
              if (!signalGroup(0)) {
                finish();
              } else {
                poll = setInterval(() => {
                  if (!signalGroup(0)) finish();
                }, 25);
              }
            });
            child.stdin.on("error", () => {});
            child.stdin.end(payload);
          }),
      )
      .catch((error: unknown) => {
        console.error("AgentHub hook:", error);
      });
    return queue;
  }

  pi.on("before_agent_start", (event) => {
    if (event.messageType === "user") prompt = event.prompt;
  });
  pi.on("message_end", (event, ctx) => {
    if (event.message.role !== "assistant") return;
    return publish(ctx, "AssistantMessage", {
      last_assistant_message: event.message.content.filter(
        (part) => part.type === "text",
      ),
    });
  });
  pi.on("context", async (event, ctx) => {
    await queue;
    if (!runId) return;
    const last = event.messages.at(-1);
    if (
      last?.role === "toolResult" &&
      /(?:read_messages|ack_messages|report_status|report_subagent_completion)$/.test(
        last.toolName,
      )
    ) {
      return;
    }
    try {
      const response = await pi.exec(
        "@command@",
        ["inbox", ctx.sessionManager.getSessionId(), runId],
        { timeout: 1500 },
      );
      if (response.code !== 0) {
        console.error("AgentHub inbox:", response.stderr);
        return;
      }
      if (!response.stdout.trim()) return;
      const value: unknown = JSON.parse(response.stdout);
      if (
        typeof value !== "object" ||
        value === null ||
        !("context" in value) ||
        typeof value.context !== "string"
      ) {
        throw new Error("Invalid AgentHub inbox response");
      }
      const prepared = {
        messages: [
          ...event.messages,
          {
            role: "user" as const,
            content: value.context,
            timestamp: Date.now(),
          },
        ],
      };
      if (!("receipt" in value)) throw new Error("Missing inbox receipt");
      try {
        const confirmed = await pi.exec(
          "@command@",
          ["delivered", JSON.stringify(value.receipt)],
          { timeout: 1500 },
        );
        if (confirmed.code !== 0)
          console.error("AgentHub inbox delivery:", confirmed.stderr);
      } catch (error) {
        console.error("AgentHub inbox delivery:", error);
      }
      return prepared;
    } catch (error) {
      console.error("AgentHub inbox:", error);
    }
  });
  pi.on("session_start", (event, ctx) => {
    process.env.AGENT_HUB_CURRENT_ID = `pi:${ctx.sessionManager.getSessionId()}`;
    running = false;
    prompts = 0;
    runId = "";
    outcome = "completed";
    return publish(ctx, "SessionStart", { source: event.reason });
  });
  pi.on("agent_start", (_event, ctx) => {
    if (running) return;
    runId = randomUUID();
    running = true;
    outcome = "completed";
    return publish(ctx, "UserPromptSubmit", { prompt });
  });
  pi.on("tool_execution_start", (event, ctx) =>
    publish(ctx, "PreToolUse", {
      tool_name: event.toolName,
      tool_use_id: event.toolCallId,
    }),
  );
  pi.on("tool_execution_end", (event, ctx) =>
    publish(ctx, "PostToolUse", {
      tool_name: event.toolName,
      tool_use_id: event.toolCallId,
      is_error: event.isError,
      tool_response: event.result,
    }),
  );
  pi.on("ui_prompt_start", (_event, ctx) => {
    prompts += 1;
    return publish(ctx, "Notification", {
      notification_type: "elicitation_dialog",
      phase: "start",
    });
  });
  pi.on("ui_prompt_end", (_event, ctx) => {
    prompts = Math.max(0, prompts - 1);
    if (prompts === 0) {
      return publish(ctx, "Notification", {
        phase: "end",
        notification_type: "elicitation_dialog",
        resume_state: running ? "running" : "idle",
      });
    }
  });
  pi.on("agent_before_settle", (event) => {
    outcome = event.outcome;
  });
  pi.on("agent_settled", (event, ctx) => {
    running = false;
    return publish(
      ctx,
      !event.aborted && outcome === "error" ? "StopFailure" : "Stop",
      {
        outcome: event.aborted ? "aborted" : outcome,
      },
    );
  });
  pi.on("session_info_changed", (event, ctx) =>
    publish(ctx, "SessionInfoChanged", { session_title: event.name ?? "" }),
  );
  pi.on("session_shutdown", (_event, ctx) => publish(ctx, "SessionEnd"));
}
