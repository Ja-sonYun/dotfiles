import { execFile } from "node:child_process";
import { Console } from "node:console";
import {
  appendFileSync,
  copyFileSync,
  existsSync,
  statSync,
  truncateSync,
} from "node:fs";
import { Writable } from "node:stream";

export function configureServiceLog(file: string): void {
  const limit = 10 * 1024 * 1024;
  const output = new Writable({
    write(chunk: Buffer, _encoding, done) {
      try {
        let offset = 0;
        while (offset < chunk.length) {
          let size = existsSync(file) ? statSync(file).size : 0;
          if (size >= limit) {
            copyFileSync(file, `${file}.1`);
            truncateSync(file, 0);
            size = 0;
          }
          const part = chunk.subarray(offset, offset + limit - size);
          appendFileSync(file, part, { mode: 0o600 });
          offset += part.length;
        }
        done();
      } catch (error) {
        done(error instanceof Error ? error : new Error(String(error)));
      }
    },
  });
  output.on("error", (error) =>
    process.stderr.write(`Service logging failed: ${error.message}\n`),
  );
  globalThis.console = new Console({ stdout: output, stderr: output });
}

function jsonBytes(value: unknown): number {
  const json = JSON.stringify(value).replace(
    /[<>&\u2028\u2029]/g,
    (character) =>
      `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`,
  );
  return Buffer.byteLength(json, "utf8");
}

export async function logContent(
  component: "slack-message-review" | "slack-thread-summary",
  context: {
    runId: string;
    stage: "review" | "messages" | "merge";
    step: number;
    final: boolean;
  },
  values: Record<string, string>,
): Promise<void> {
  const logger = process.env.SLACK_CODEX_LOG_COMMAND;
  if (!logger) return;
  const emptyContentBytes = jsonBytes(JSON.stringify(""));
  for (const [field, value] of Object.entries(values)) {
    const fields = {
      run_id: context.runId,
      stage: context.stage,
      step: String(context.step),
      final: String(context.final),
      field,
      encoding: "json",
    };
    // Budget the Go sender's HTML escaping, longest timestamp, PID and newline.
    const budget =
      32768 -
      jsonBytes({
        time: "2000-01-01T00:00:00.000000000Z",
        component,
        level: "info",
        event: "content",
        pid: Number.MAX_SAFE_INTEGER,
        fields: {
          ...fields,
          part: String(value.length || 1),
          parts: String(value.length || 1),
          content: JSON.stringify(""),
        },
      }) -
      1;
    const chunks: string[] = [];
    let chunk = "";
    let bytes = 0;
    for (const character of value) {
      const size = jsonBytes(JSON.stringify(character)) - emptyContentBytes;
      if (bytes + size > budget) {
        chunks.push(chunk);
        chunk = "";
        bytes = 0;
      }
      chunk += character;
      bytes += size;
    }
    chunks.push(chunk);
    for (const [index, content] of chunks.entries()) {
      // JSON-encode each part so control characters never enter argv literally.
      const entry = {
        ...fields,
        part: String(index + 1),
        parts: String(chunks.length),
        content: JSON.stringify(content),
      };
      try {
        await new Promise<void>((resolve) => {
          execFile(
            logger,
            [
              component,
              "info",
              "content",
              ...Object.entries(entry).map(([key, text]) => `${key}=${text}`),
            ],
            { timeout: 1000 },
            () => resolve(),
          );
        });
      } catch {
        return;
      }
    }
  }
}
