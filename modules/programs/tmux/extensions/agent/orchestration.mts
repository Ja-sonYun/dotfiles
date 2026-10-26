import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import type { ChildProcessByStdio } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import {
  command,
  validate,
  panes,
  register,
  observe,
  location,
  object,
  string,
  number,
  readLocation,
  type Location,
  type Registration,
} from "./orchestration-observe.mjs";

const connections = new Map<string, Connection>();

async function monitor(operation: string, input: unknown): Promise<unknown> {
  const target = await location();
  const current = (await panes(target.socket)).find(
    (pane) => pane.pane === target.pane && pane.scope === target.scope,
  );
  if (!current || !/^_popup_.*_agent-hub$/.test(current.name)) {
    throw new Error("This operation requires the monitor's own tmux session");
  }
  if (operation === "detach") {
    await command(
      target.socket,
      "detach-client",
      "-E",
      "true",
      "-s",
      target.session,
    );
    return { detached: true };
  }
  if (operation === "view-save") {
    const request = object(input);
    if (request.scope !== target.scope)
      throw new Error("Monitor session changed");
    await command(
      target.socket,
      "set-option",
      "-t",
      target.session,
      "@agent_hub_view",
      JSON.stringify(request),
    );
    return { saved: true };
  }
  const saved = await command(
    target.socket,
    "show-option",
    "-qv",
    "-t",
    target.session,
    "@agent_hub_view",
  );
  const value = saved ? object(JSON.parse(saved)) : null;
  return {
    scope: target.scope,
    server: target.server,
    view: value !== null && value.scope === target.scope ? value.view : null,
  };
}

class Connection {
  nextId = 0;
  pending = new Map<
    number,
    {
      resolve: (value: unknown) => void;
      reject: (error: unknown) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  child: ChildProcessByStdio<Writable, Readable, null>;
  ready: Promise<void>;

  constructor(location: Location) {
    this.child = spawn("@tmuxMcp@", ["--config", "@tmuxConfig@"], {
      env: {
        ...process.env,
        TMUX: `${location.socket},0,${location.session.slice(1)}`,
      },
      stdio: ["pipe", "pipe", "inherit"],
    });
    this.child.stdin.on("error", (error) => this.fail(error));
    this.child.on("error", (error) => this.fail(error));
    this.child.on("close", () => {
      this.fail(new Error("tmux MCP disconnected"));
      if (connections.get(location.socket) === this) {
        connections.delete(location.socket);
      }
    });
    createInterface({ input: this.child.stdout }).on("line", (line) => {
      try {
        const response = object(JSON.parse(line));
        if (typeof response.id !== "number") return;
        const waiting = this.pending.get(response.id);
        if (!waiting) {
          return;
        }
        this.pending.delete(response.id);
        clearTimeout(waiting.timer);
        if (response.error) {
          waiting.reject(new Error(string(object(response.error).message)));
        } else {
          waiting.resolve(response.result);
        }
      } catch (error) {
        this.fail(error);
      }
    });
    this.ready = this.call("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "agent-hub-observer", version: "0.1.0" },
    }).then(() => {
      this.child.stdin.write(
        `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`,
      );
    });
  }

  fail(error: unknown): void {
    for (const waiting of this.pending.values()) {
      clearTimeout(waiting.timer);
      waiting.reject(error);
    }
    this.pending.clear();
  }

  call(method: string, params: unknown): Promise<unknown> {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("tmux MCP query timed out"));
      }, 12000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(
        `${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`,
      );
    });
  }
}

export async function capture(
  input: unknown,
  offset = 0,
  signal?: AbortSignal,
): Promise<unknown> {
  const target = readLocation(input);
  signal?.throwIfAborted();
  await validate(target);
  let connection = connections.get(target.socket);
  if (!connection) {
    connection = new Connection(target);
    connections.set(target.socket, connection);
  }
  await connection.ready;
  const response = object(
    await connection.call("tools/call", {
      name: "capture_pane",
      arguments: { pane_id: target.pane, lines: 200, offset },
    }),
  );
  signal?.throwIfAborted();
  const content = Array.isArray(response.content)
    ? response.content.map(object)
    : [];
  const text = content.find(
    (item) => item.type === "text" && typeof item.text === "string",
  )?.text;
  if (response.isError) {
    throw new Error(typeof text === "string" ? text : "Capture failed");
  }
  await validate(target);
  if (response.structuredContent) {
    return response.structuredContent;
  }
  return JSON.parse(string(text));
}

async function endEmbedded(input: unknown, cleanup: boolean): Promise<void> {
  const request = object(input);
  const target = readLocation(request.location);
  const token = string(request.token);
  if (!/^[0-9a-f-]{36}$/.test(token)) throw new Error("Invalid viewer token");
  const view = `_agent_hub_view_${token}`;
  const errors: unknown[] = [];
  try {
    const clients = await command(
      target.socket,
      "list-clients",
      "-F",
      "#{client_tty}\t#{session_name}\t#{client_pid}",
    );
    for (const line of clients.split("\n")) {
      const [tty, session, pid] = line.split("\t");
      if (session === view) {
        const marker = `@agent_hub_client_${string(pid)}`;
        try {
          if (
            (await command(target.socket, "show-option", "-svq", marker)) ===
            token
          ) {
            await command(target.socket, "set-option", "-suq", marker);
          }
        } catch (error) {
          errors.push(error);
        }
        try {
          await command(
            target.socket,
            "detach-client",
            "-E",
            "true",
            "-t",
            string(tty),
          );
        } catch (error) {
          errors.push(error);
        }
      }
    }
  } catch (error) {
    errors.push(error);
  }
  if (cleanup) {
    try {
      if ((await panes(target.socket)).some((pane) => pane.name === view)) {
        await command(target.socket, "kill-session", "-t", view);
      }
    } catch (error) {
      errors.push(error);
    }
    try {
      const source = await location();
      const owner = await command(
        source.socket,
        "show-option",
        "-pqv",
        "-t",
        source.pane,
        "@agent_hub_embedded",
      );
      const saved = owner ? object(JSON.parse(owner)) : null;
      if (saved?.token === token) {
        await command(
          source.socket,
          "set-option",
          "-t",
          source.session,
          "key-table",
          string(saved.key_table),
        );
        await command(
          source.socket,
          "set-option",
          "-pu",
          "-t",
          source.pane,
          "@agent_hub_embedded",
        );
      }
    } catch (error) {
      errors.push(error);
    }
  }
  if (errors.length) {
    throw new AggregateError(
      errors,
      `Viewer cleanup failed:\n${errors.map((error) => (error instanceof Error ? error.message : String(error))).join("\n")}`,
    );
  }
}

async function attachEmbedded(input: unknown): Promise<void> {
  const request = object(input);
  const target = readLocation(request.location);
  const token = string(request.token);
  if (!/^[0-9a-f-]{36}$/.test(token)) throw new Error("Invalid viewer token");
  await validate(target);
  const source = await location();
  const sourcePane = (await panes(source.socket)).find(
    (pane) => pane.pane === source.pane && pane.scope === source.scope,
  );
  if (!sourcePane || !/^_popup_.*_agent-hub$/.test(sourcePane.name)) {
    throw new Error(
      "Embedded attachment requires the monitor's own tmux session",
    );
  }
  const view = `_agent_hub_view_${token}`;
  const errors: unknown[] = [];
  let stopped = false;
  let stopping: Promise<void> | null = null;
  const stop = () => {
    stopped = true;
    stopping ??= endEmbedded(input, false).catch((error: unknown) => {
      errors.push(error);
    });
  };
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"])
    process.on(signal, stop);
  let marker: string | null = null;
  try {
    const keyTable = await command(
      source.socket,
      "show-option",
      "-qv",
      "-t",
      source.session,
      "key-table",
    );
    await command(
      source.socket,
      "set-option",
      "-p",
      "-t",
      source.pane,
      "@agent_hub_embedded",
      JSON.stringify({ token, key_table: keyTable }),
    );
    await command(
      source.socket,
      "set-option",
      "-t",
      source.session,
      "key-table",
      "agent-hub-input",
    );
    await command(
      target.socket,
      "new-session",
      "-d",
      "-t",
      target.session,
      "-s",
      view,
      "-e",
      "AGENT_HUB_POPUP=1",
    );
    for (const [key, value] of [
      ["status", "off"],
      ["key-table", "agent-hub-view"],
      ["prefix", "None"],
      ["prefix2", "None"],
    ] as const) {
      await command(target.socket, "set-option", "-t", view, key, value);
    }
    await command(
      target.socket,
      "select-window",
      "-t",
      `${view}:${target.window}`,
    );
    await command(
      target.socket,
      "select-pane",
      "-t",
      `${view}:${target.window}.${target.pane}`,
    );
    if (!stopped) {
      const env = { ...process.env };
      delete env.TMUX;
      delete env.TMUX_PANE;
      const child = spawn("@attach@", [target.socket, view, token], {
        env,
        stdio: "inherit",
      });
      marker = child.pid ? `@agent_hub_client_${child.pid}` : null;
      process.stdout.write(`\x1b]777;agent-hub-ready;${token}\x07`);
      const code = await new Promise<number>((resolve, reject) => {
        child.once("error", reject);
        child.once("close", (code) => resolve(code ?? 1));
      });
      if (code !== 0)
        throw new Error(`Agent connection exited with status ${code}`);
    }
  } catch (error) {
    errors.unshift(error);
  } finally {
    for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"])
      process.off(signal, stop);
    await stopping;
    try {
      await endEmbedded(input, true);
    } catch (error) {
      errors.push(error);
    }
    try {
      if (
        marker &&
        (await command(target.socket, "show-option", "-svq", marker)) === token
      ) {
        await command(target.socket, "set-option", "-suq", marker);
      }
    } catch (error) {
      errors.push(error);
    }
  }
  if (errors.length) {
    throw new AggregateError(
      errors,
      `Agent connection failed:\n${errors.map((error) => (error instanceof Error ? error.message : String(error))).join("\n")}`,
    );
  }
}

export async function close(): Promise<void> {
  await Promise.all(
    [...connections.values()].map(
      (connection) =>
        new Promise<void>((resolve) => {
          if (connection.child.exitCode !== null) {
            resolve();
            return;
          }
          const timer = setTimeout(
            () => connection.child.kill("SIGKILL"),
            1500,
          );
          connection.child.once("close", () => {
            clearTimeout(timer);
            resolve();
          });
          connection.child.stdin.end();
          connection.child.kill("SIGTERM");
        }),
    ),
  );
  connections.clear();
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    const operation = process.argv[2];
    if (operation === "location") {
      process.stdout.write(JSON.stringify(await location()));
    } else {
      let input = process.argv[3];
      if (!input) {
        const chunks: Buffer[] = [];
        for await (const chunk of process.stdin) {
          if (!Buffer.isBuffer(chunk)) throw new Error("Expected binary stdin");
          chunks.push(chunk);
        }
        input = Buffer.concat(chunks).toString("utf8");
      }
      const value: unknown = JSON.parse(input);
      if (operation === "attach-embedded") {
        await attachEmbedded(value);
      } else if (
        operation === "embedded-stop" ||
        operation === "embedded-cleanup"
      ) {
        await endEmbedded(value, operation === "embedded-cleanup");
        process.stdout.write(JSON.stringify({ detached: true }));
      } else if (operation === "register") {
        const request = object(value);
        const identity = string(request.identity);
        if (!["root", "child", "unknown"].includes(identity))
          throw new Error("Invalid session identity");
        const target: Registration = {
          client: string(request.client),
          session_id: string(request.session_id),
          parent: request.parent == null ? null : string(request.parent),
          identity:
            identity === "root"
              ? "root"
              : identity === "child"
                ? "child"
                : "unknown",
          event: string(request.event),
          at: number(request.at),
        };
        process.stdout.write(JSON.stringify(await register(target)));
      } else if (operation === "observe") {
        if (!Array.isArray(value)) throw new Error("Expected an agent array");
        const target = value.map((item: unknown) => {
          const agent = object(item);
          return {
            id: string(agent.id),
            parent: agent.parent == null ? null : string(agent.parent),
            location: readLocation(agent.location),
          };
        });
        process.stdout.write(JSON.stringify(await observe(target)));
      } else if (
        operation &&
        ["view-load", "view-save", "detach"].includes(operation)
      ) {
        process.stdout.write(JSON.stringify(await monitor(operation, value)));
      } else {
        const target = readLocation(value);
        await validate(target);
        if (operation === "validate") {
          process.stdout.write(JSON.stringify({ valid: true }));
        } else {
          throw new Error("Unknown tmux adapter operation");
        }
      }
    }
  } catch (error) {
    process.stderr.write(
      `${error instanceof Error ? error.message : String(error)}\n`,
    );
    process.exitCode = 1;
  }
}
