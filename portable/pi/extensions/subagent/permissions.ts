import type { ChildProcess } from "node:child_process";
import type { RuntimeContext } from "../permissions/rules.ts";

export interface PermissionBridge {
  extension: string;
  mode: "default" | "plan";
  additionalTools?: string[];
  check: (
    call: { toolName: string; input: Record<string, unknown> },
    signal: AbortSignal,
    runtimeContext: RuntimeContext,
  ) => Promise<{ block: true; reason: string } | undefined>;
  rules: (
    call: { toolName: string; input: Record<string, unknown> },
    signal: AbortSignal,
    runtimeContext: RuntimeContext,
  ) => Promise<Record<string, unknown>>;
}

export function connectPermissions(
  child: ChildProcess,
  bridge: PermissionBridge,
  signal?: AbortSignal,
): void {
  const lifetime = new AbortController();
  const cancellation = AbortSignal.any([
    lifetime.signal,
    ...(signal ? [signal] : []),
  ]);
  const pending = new Map<string, AbortController>();
  let sessionId: string | undefined;
  child.on("message", async (message: any) => {
    if (message?.type === "pi:permission:cancel") {
      pending.get(message.id)?.abort();
      return;
    }
    if (
      !["pi:permission:check", "pi:permission:rules"].includes(message?.type) ||
      typeof message.id !== "string"
    )
      return;
    if (pending.has(message.id)) return;
    const controller = new AbortController();
    pending.set(message.id, controller);
    const requestSignal = AbortSignal.any([cancellation, controller.signal]);
    let outcome: { block: true; reason: string } | undefined;
    let result: Record<string, unknown> | undefined;
    try {
      if (
        requestSignal.aborted ||
        typeof message.call?.toolName !== "string" ||
        !message.call.input ||
        typeof message.call.input !== "object"
      ) {
        throw new Error("Invalid child permission request");
      }
      const runtime = message.runtime_context;
      const identity = runtime?.session_identity;
      if (
        identity?.client !== "pi" ||
        typeof identity.session_id !== "string" ||
        !identity.session_id ||
        identity.agent_id !== `pi:${identity.session_id}` ||
        (sessionId !== undefined && sessionId !== identity.session_id) ||
        typeof runtime.runtime_instructions !== "string" ||
        (runtime.tool_metadata !== null &&
          (runtime.tool_metadata?.name !== message.call.toolName ||
            typeof runtime.tool_metadata?.description !== "string"))
      ) {
        throw new Error("Invalid child runtime context");
      }
      sessionId = identity.session_id;
      if (message.type === "pi:permission:rules") {
        result = await bridge.rules(message.call, requestSignal, runtime);
      } else {
        outcome = await bridge.check(message.call, requestSignal, runtime);
      }
    } catch {
      outcome = { block: true, reason: "Parent permission check failed" };
    }
    pending.delete(message.id);
    if (child.connected && !requestSignal.aborted) {
      child.send(
        {
          type: "pi:permission:result",
          id: message.id,
          allow: !outcome,
          reason: outcome?.reason,
          result,
        },
        () => {},
      );
    }
  });
  child.once("disconnect", () => lifetime.abort());
  child.once("close", () => lifetime.abort());
}
