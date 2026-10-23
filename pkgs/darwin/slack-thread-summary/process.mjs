import { spawn } from "node:child_process";

export function start(
  command,
  args,
  environment = process.env,
  terminationGraceMs = 800,
) {
  const child = spawn(command, args, {
    cwd: process.env.SLACK_THREAD_SUMMARY_STATE_DIRECTORY,
    env: environment,
    detached: true,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "";
  let diagnostics = "";
  let bytes = 0;
  let failure;
  let closed = false;
  const done = new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", () => {
      void stop().catch(() => {});
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > 1024 * 1024) {
        failure = new Error("Process output exceeded 1 MiB.");
        void stop().catch(() => {});
        return;
      }
      output += chunk;
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      diagnostics = (diagnostics + chunk).slice(-4000);
    });
    child.stdin.on("error", () => {});
    child.on("close", (code, signal) => {
      closed = true;
      if (failure || code !== 0) {
        reject(
          failure ??
            new Error(`${command} exited: ${signal ?? code}\n${diagnostics}`),
        );
      } else {
        resolve(output);
      }
    });
  });
  done.catch(() => {});
  let stopping;
  function stop() {
    if (stopping) {
      return stopping;
    }
    if (closed) {
      return Promise.resolve();
    }
    stopping = (async () => {
      if (!child.pid) {
        return;
      }
      // The spawned CLI owns the process group targeted by cancellation.
      try {
        process.kill(-child.pid, "SIGTERM");
      } catch (error) {
        if (error.code === "ESRCH") {
          return;
        }
        throw error;
      }
      // Let wrappers finish their own child cleanup before escalating.
      await new Promise((resolve) => setTimeout(resolve, terminationGraceMs));
      try {
        process.kill(-child.pid, 0);
        process.kill(-child.pid, "SIGKILL");
      } catch (error) {
        if (error.code !== "ESRCH") {
          throw error;
        }
      }
      await done.catch(() => {});
    })();
    return stopping;
  }
  return { child, done, stop };
}
