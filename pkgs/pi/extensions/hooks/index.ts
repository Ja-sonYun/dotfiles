import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";

// Replaced with the pi-fire-hook store path at build time.
const FIRE = "@fireHook@";

const IDLE_MS = 60_000;

export default function (pi: ExtensionAPI) {
  const fire = (event: string, subject = "") =>
    execFile(FIRE, [event, subject], () => {});

  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  const clearIdle = () => {
    if (idleTimer) {
      clearTimeout(idleTimer);
      idleTimer = undefined;
    }
  };

  pi.on("session_start", (e) =>
    fire("SessionStart", (e as { reason?: string }).reason ?? ""),
  );
  pi.on("agent_start", () => {
    clearIdle();
    fire("UserPromptSubmit");
  });
  pi.on("tool_call", (e) =>
    fire("PreToolUse", (e as { toolName?: string }).toolName ?? ""),
  );
  pi.on("tool_execution_start", (e) => {
    fire("ElicitationResult");
    fire("PostToolUse", (e as { toolName?: string }).toolName ?? "");
  });
  pi.on("tool_execution_end", (e) =>
    fire("PostToolUse", (e as { toolName?: string }).toolName ?? ""),
  );
  pi.on("turn_start", () => fire("TurnStart"));
  pi.on("agent_end", () => {
    fire("Stop");
    clearIdle();
    idleTimer = setTimeout(() => fire("Notification", "idle_prompt"), IDLE_MS);
    idleTimer.unref();
  });
  pi.on("session_shutdown", () => {
    clearIdle();
    fire("SessionEnd");
  });
}
