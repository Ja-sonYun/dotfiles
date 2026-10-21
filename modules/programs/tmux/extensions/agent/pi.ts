import { spawn } from "node:child_process";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  if (
    process.env.PI_PERMISSION_CHILD === "1" ||
    process.env.AI_AGENT_SUBAGENT === "1" ||
    !process.env.TMUX_PANE
  ) {
    return;
  }

  let queue = Promise.resolve();
  let running = false;
  let prompts = 0;
  let outcome = "completed";

  function publish(
    ctx: ExtensionContext,
    event: string,
    fields: Record<string, unknown> = {},
  ): Promise<void> {
    const payload = JSON.stringify({
      hook_event_name: event,
      session_id: ctx.sessionManager.getSessionId(),
      session_title: ctx.sessionManager.getSessionName() ?? "",
      cwd: ctx.cwd,
      ...fields,
    });
    const env = { ...process.env, AI_AGENT_CLIENT: "Pi" };
    queue = queue.then(
      () =>
        new Promise<void>((resolve) => {
          const child = spawn("@statusCommand@", ["@statusScript@"], {
            env,
            stdio: ["pipe", "ignore", "ignore"],
          });
          child.on("error", () => resolve());
          child.on("close", () => resolve());
          child.stdin.on("error", () => {});
          child.stdin.end(payload);
        }),
    );
    return queue;
  }

  pi.on("session_start", (event, ctx) => {
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
