import { Worker } from "node:worker_threads";

export async function redact(
  input: Buffer,
  signal?: AbortSignal,
): Promise<Buffer> {
  if (signal?.aborted) throw new Error("aborted");
  if (input.length > 16 * 1024 * 1024)
    throw new Error("Redact output limit exceeded (16 MiB)");

  const worker = new Worker(new URL("./worker.ts", import.meta.url), {
    execArgv: ["--experimental-strip-types", "--no-warnings"],
    workerData: {
      input,
      env: {
        ...process.env,
      },
    },
  });

  let timer: ReturnType<typeof setTimeout> | undefined;
  let abort: (() => void) | undefined;
  try {
    const output = await new Promise<Buffer>((resolve, reject) => {
      const fail = () => reject(new Error("Redact failed; output withheld"));
      abort = () => reject(new Error("aborted"));
      timer = setTimeout(fail, 10000);
      signal?.addEventListener("abort", abort, { once: true });
      worker.once("error", fail);
      worker.once("exit", fail);
      worker.once("message", (message) => {
        if (message?.output instanceof Uint8Array)
          resolve(Buffer.from(message.output));
        else fail();
      });
      if (signal?.aborted) abort();
    });
    if (signal?.aborted) throw new Error("aborted");
    return output;
  } finally {
    clearTimeout(timer);
    if (abort) signal?.removeEventListener("abort", abort);
    await worker.terminate();
  }
}
