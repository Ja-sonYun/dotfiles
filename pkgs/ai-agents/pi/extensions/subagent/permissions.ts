import type { ChildProcess } from "node:child_process";

export interface PermissionBridge {
  extension: string;
  mode: "default" | "plan";
  check: (
    call: { toolName: string; input: Record<string, unknown> },
    signal: AbortSignal,
  ) => Promise<{ block: true; reason: string } | undefined>;
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
  const pending = new Set<string>();
  child.on("message", async (message: any) => {
    if (
      message?.type !== "pi:permission:check" ||
      typeof message.id !== "string"
    )
      return;
    if (pending.has(message.id)) return;
    pending.add(message.id);
    let outcome: { block: true; reason: string } | undefined;
    try {
      if (
        cancellation.aborted ||
        typeof message.call?.toolName !== "string" ||
        !message.call.input ||
        typeof message.call.input !== "object"
      ) {
        throw new Error("Invalid child permission request");
      }
      outcome = await bridge.check(message.call, cancellation);
    } catch {
      outcome = { block: true, reason: "Parent permission check failed" };
    }
    pending.delete(message.id);
    if (child.connected && !cancellation.aborted) {
      child.send(
        {
          type: "pi:permission:result",
          id: message.id,
          allow: !outcome,
          reason: outcome?.reason,
        },
        () => {},
      );
    }
  });
  child.once("disconnect", () => lifetime.abort());
  child.once("close", () => lifetime.abort());
}
