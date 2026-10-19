import { spawn } from "node:child_process";
import { exchange } from "./transport.ts";

export async function runJson(
  command: string[],
  input: unknown,
  cwd: string,
  signal: AbortSignal,
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new Error("Cancelled"));
      return;
    }
    const child = spawn(command[0], command.slice(1), {
      cwd,
      detached: true,
      stdio: ["pipe", "pipe", "ignore"],
    });
    let output = Buffer.alloc(0);
    let result: unknown;
    let done = false;
    const active = new Map<number, AbortController>();
    const used = new Set<number>();
    const pending = new Set<Promise<void>>();
    let failed = false;
    let cleanup: Promise<void> | undefined;
    const stop = () => {
      if (failed) return;
      failed = true;
      for (const controller of active.values()) controller.abort();
      const send = (name: NodeJS.Signals | 0): boolean => {
        try {
          if (!child.pid) return false;
          process.kill(-child.pid, name);
          return true;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
          return false;
        }
      };
      cleanup = (async () => {
        if (!send("SIGTERM")) return;
        const deadline = Date.now() + 1000;
        while (Date.now() < deadline) {
          if (!send(0)) return;
          await new Promise((done) => setTimeout(done, 25));
        }
        if (send(0)) send("SIGKILL");
      })();
      cleanup.catch(reject);
    };
    const write = (value: unknown) =>
      new Promise<void>((finish, fail) => {
        const line = JSON.stringify(value) + "\n";
        if (Buffer.byteLength(line) > 1024 * 1024) {
          fail(new Error("Rule transport frame exceeded"));
          return;
        }
        child.stdin.write(line, (error) => (error ? fail(error) : finish()));
      });
    const handle = async (frame: any) => {
      if (done || !frame || typeof frame !== "object")
        throw new Error("Invalid rule transport");
      if (frame.type === "done") {
        done = true;
        result = frame.value;
        child.stdin.end();
        return;
      }
      if (!Number.isSafeInteger(frame.id) || frame.id <= 0)
        throw new Error("Invalid rule request");
      if (frame.type === "cancel") {
        active.get(frame.id)?.abort();
        return;
      }
      if (
        !["redact", "http"].includes(frame.type) ||
        used.has(frame.id) ||
        typeof frame.timeout !== "number" ||
        !Number.isFinite(frame.timeout) ||
        frame.timeout <= 0 ||
        frame.timeout > 10
      )
        throw new Error("Invalid rule request");
      used.add(frame.id);
      const controller = new AbortController();
      active.set(frame.id, controller);
      const timer = setTimeout(() => controller.abort(), frame.timeout * 1000);
      try {
        const value = await exchange(frame, controller.signal);
        if (!failed && !child.stdin.writableEnded)
          await write({ id: frame.id, value });
      } catch {
        if (!failed && !child.stdin.writableEnded)
          await write({
            id: frame.id,
            error: controller.signal.aborted ? "timeout" : "request",
          });
      } finally {
        clearTimeout(timer);
        active.delete(frame.id);
      }
    };
    const timeout = setTimeout(stop, 35000);
    signal.addEventListener("abort", stop, { once: true });
    child.stdin.on("error", stop);
    child.stdout.on("data", (chunk: Buffer) => {
      if (failed) return;
      output = Buffer.concat([output, chunk]);
      let newline: number;
      while ((newline = output.indexOf(10)) >= 0) {
        const line = output.subarray(0, newline);
        output = output.subarray(newline + 1);
        if (line.length + 1 > 1024 * 1024 || done) {
          stop();
          return;
        }
        try {
          const task = handle(JSON.parse(line.toString("utf8")));
          pending.add(task);
          task.catch(stop).finally(() => pending.delete(task));
        } catch {
          stop();
          return;
        }
      }
      if (output.length >= 1024 * 1024) stop();
    });
    child.on("error", reject);
    child.on("close", async (code) => {
      clearTimeout(timeout);
      signal.removeEventListener("abort", stop);
      try {
        await cleanup;
        await Promise.all(pending);
        if (failed || code !== 0 || !done || output.length)
          throw new Error("Rule evaluator failed");
        resolve(result);
      } catch (error) {
        reject(error);
      }
    });
    write(input).catch(stop);
    if (signal.aborted) stop();
  });
}
