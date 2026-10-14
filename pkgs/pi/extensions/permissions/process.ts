import { spawn } from "node:child_process";

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
    let output = "";
    let failed = false;
    let cleanup: Promise<void> | undefined;
    const stop = () => {
      if (failed) return;
      failed = true;
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
    const timeout = setTimeout(stop, 35000);
    signal.addEventListener("abort", stop, { once: true });
    child.stdin.on("error", stop);
    child.stdout.on("data", (chunk) => {
      output += chunk;
      if (Buffer.byteLength(output) > 1024 * 1024) stop();
    });
    child.on("error", reject);
    child.on("close", async (code) => {
      clearTimeout(timeout);
      signal.removeEventListener("abort", stop);
      try {
        await cleanup;
        if (failed || code !== 0) throw new Error("Rule evaluator failed");
        resolve(JSON.parse(output));
      } catch (error) {
        reject(error);
      }
    });
    child.stdin.end(JSON.stringify(input));
  });
}
