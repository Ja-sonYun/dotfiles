import type { BashOperations } from "@earendil-works/pi-coding-agent";
import { redact } from "../../redaction/index.ts";

const maxOutputBytes = 16 * 1024 * 1024;

export function createRedactedOperations(
  local: BashOperations,
): BashOperations {
  return {
    async exec(command, cwd, options) {
      if (options.signal?.aborted) throw new Error("aborted");

      const controller = new AbortController();
      const signal = options.signal
        ? AbortSignal.any([options.signal, controller.signal])
        : controller.signal;
      const chunks: Buffer[] = [];
      let bytes = 0;
      let exceeded = false;
      let result;
      try {
        result = await local.exec(command, cwd, {
          ...options,
          signal,
          onData(data) {
            if (exceeded) return;
            bytes += data.length;
            if (bytes > maxOutputBytes) {
              exceeded = true;
              chunks.length = 0;
              controller.abort();
              return;
            }
            chunks.push(Buffer.from(data));
          },
        });
      } catch (error) {
        if (exceeded) throw new Error("Redact output limit exceeded (16 MiB)");
        if (options.signal?.aborted) throw new Error("aborted");
        if (
          options.timeout !== undefined &&
          error instanceof Error &&
          error.message === `timeout:${options.timeout}`
        ) {
          throw new Error(`timeout:${options.timeout}`);
        }
        throw new Error("Command execution failed; output withheld");
      }
      if (exceeded) throw new Error("Redact output limit exceeded (16 MiB)");
      if (options.signal?.aborted) throw new Error("aborted");

      const input = Buffer.concat(chunks, bytes);
      chunks.length = 0;
      const output = await redact(input, options.signal);
      options.onData(output);
      return result;
    },
  };
}
