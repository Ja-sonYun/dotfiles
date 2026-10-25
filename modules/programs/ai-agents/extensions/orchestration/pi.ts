import { spawn } from "node:child_process";
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
  const { parentId } = (runtime[parentStateKey] ??= {
    parentId: process.env.AGENT_HUB_CURRENT_ID,
  });
  let queue = Promise.resolve();
  let running = false;
  let outcome = "completed";
  let prompts = 0;

  pi.registerMcpServer("orchestration", {
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
    systemPrompt: `${event.systemPrompt}\n\nReport task start, step changes, delegation, blockers and completion through orchestration MCP. Your client is pi and your session_id is ${ctx.sessionManager.getSessionId()}. Report only your own session; approval remains in the original CLI.`,
  }));
  pi.on("session_start", (event, ctx) => {
    process.env.AGENT_HUB_CURRENT_ID = `pi:${ctx.sessionManager.getSessionId()}`;
    running = false;
    prompts = 0;
    outcome = "completed";
    return publish(ctx, "SessionStart", { source: event.reason });
  });
  pi.on("agent_start", (_event, ctx) => {
    running = true;
    outcome = "completed";
    return publish(ctx, "UserPromptSubmit");
  });
  pi.on("tool_execution_start", (event, ctx) =>
    publish(ctx, "PreToolUse", { tool_name: event.toolName }),
  );
  pi.on("tool_execution_end", (event, ctx) =>
    publish(ctx, "PostToolUse", {
      tool_name: event.toolName,
      is_error: event.isError,
    }),
  );
  pi.on("ui_prompt_start", (_event, ctx) => {
    prompts += 1;
    return publish(ctx, "Notification", { phase: "start" });
  });
  pi.on("ui_prompt_end", (_event, ctx) => {
    prompts = Math.max(0, prompts - 1);
    if (prompts === 0) {
      return publish(ctx, "Notification", {
        phase: "end",
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
