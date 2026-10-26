import { spawn } from "node:child_process";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { hasErrorCode } from "./contracts.mjs";

export function requiredSetting(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing service setting: ${name}`);
  return value;
}

export interface RunningProcess {
  child: ChildProcessWithoutNullStreams;
  done: Promise<string>;
  stop(): Promise<void>;
}

export function start(
  command: string,
  args: string[],
  environment: NodeJS.ProcessEnv = process.env,
  terminationGraceMs = 800,
): RunningProcess {
  const child = spawn(command, args, {
    cwd: process.env.SLACK_REVIEW_STATE_DIRECTORY,
    env: environment,
    detached: true,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "";
  let diagnostics = "";
  let bytes = 0;
  let failure: Error | undefined;
  let closed = false;
  const done = new Promise<string>((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", () => {
      void stop().catch(() => {});
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > 1024 * 1024) {
        failure = new Error("Process output exceeded 1 MiB.");
        void stop().catch(() => {});
        return;
      }
      output += chunk;
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
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
  let stopping: Promise<void> | undefined;
  function stop(): Promise<void> {
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
        if (hasErrorCode(error, "ESRCH")) {
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
        if (!hasErrorCode(error, "ESRCH")) {
          throw error;
        }
      }
      await done.catch(() => {});
    })();
    return stopping;
  }
  return { child, done, stop };
}
