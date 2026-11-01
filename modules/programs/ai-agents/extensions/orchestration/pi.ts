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
    queue = queue.then(
      () =>
        new Promise<void>((resolve) => {
          const child = spawn("@command@", ["hook"], {
            env,
            stdio: ["pipe", "ignore", "inherit"],
          });
          child.on("error", () => resolve());
          child.on("close", () => resolve());
          child.stdin.on("error", () => {});
          child.stdin.end(payload);
        }),
    );
    return queue;
  }

  pi.on("before_agent_start", (event, ctx) => ({
    systemPrompt: `${event.systemPrompt}\n\nReport task start, step changes, delegation, blockers and completion through orchestration MCP. Call the exposed mcp__orchestration__* tools directly; do not use tool_search or codemode solely to call AgentHub. Your client is pi and your session_id is ${ctx.sessionManager.getSessionId()}. Report only your own session; approval remains in the original CLI.`,
  }));
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
      return {
        messages: [
          ...event.messages,
          {
            role: "user" as const,
            content: value.context,
            timestamp: Date.now(),
          },
        ],
      };
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
    runId = randomUUID();
    running = true;
    outcome = "completed";
    return publish(ctx, "UserPromptSubmit");
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
