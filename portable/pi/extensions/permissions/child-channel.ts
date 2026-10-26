import { randomUUID } from "node:crypto";
import type { Call } from "./policy.ts";

interface ParentResponse {
  allow: boolean;
  reason?: string;
  result?: Record<string, unknown>;
}

export function parentRequest(
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
