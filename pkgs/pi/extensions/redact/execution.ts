import { execFile } from "node:child_process";
import type { BashOperations } from "@earendil-works/pi-coding-agent";

const maxOutputBytes = 16 * 1024 * 1024;

export async function redactOutput(
  input: Buffer,
  cwd: string,
  executable: string | undefined,
  signal?: AbortSignal,
): Promise<Buffer> {
  if (signal?.aborted) throw new Error("aborted");
  if (!executable) throw new Error("Redact executable is not configured");
  if (input.length > maxOutputBytes)
    throw new Error("Redact output limit exceeded (16 MiB)");

  const output = await new Promise<Buffer>((resolve, reject) => {
    let inputFailed = false;
    const child = execFile(
      executable,
      [],
      {
        cwd,
        encoding: "buffer",
        maxBuffer: 32 * 1024 * 1024,
        timeout: 10000,
        killSignal: "SIGKILL",
        signal,
      },
      (error, stdout) => {
        if (signal?.aborted) {
          reject(new Error("aborted"));
        } else if (error || inputFailed) {
          reject(new Error("Redact failed; output withheld"));
        } else {
          resolve(stdout);
        }
      },
    );
    child.stdin!.on("error", () => {
      inputFailed = true;
      child.kill("SIGKILL");
    });
    child.stdin!.end(input);
  });
  if (signal?.aborted) throw new Error("aborted");
  return output;
}

export function createRedactedOperations(
  local: BashOperations,
  executable: string | undefined,
): BashOperations {
  return {
    async exec(command, cwd, options) {
      if (options.signal?.aborted) throw new Error("aborted");
      if (!executable) throw new Error("Redact executable is not configured");

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
      const output = await redactOutput(input, cwd, executable, options.signal);
      options.onData(output);
      return result;
    },
  };
}
