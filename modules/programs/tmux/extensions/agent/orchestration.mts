import { execFile, spawn } from "node:child_process";
import { stat } from "node:fs/promises";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";
import type { ChildProcessByStdio } from "node:child_process";
import type { Readable, Writable } from "node:stream";

interface Location {
  socket: string;
  session: string;
  window: string;
  pane: string;
  server?: string;
  scope?: string;
  process_id?: number;
  process_started?: string;
}

interface Owner {
  id: string;
  pid: number;
  started: string;
  at: number;
}

interface Pane extends Location {
  pane_pid: number;
  dead: boolean;
  name: string;
  owner: Owner | null;
}

interface ProcessInfo {
  pid: number;
  parent: number;
  started: string;
  args: string;
}

interface Registration {
  client: string;
  session_id: string;
  parent: string | null;
  event: string;
  at: number;
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("Expected a JSON object");
  return value as Record<string, unknown>;
}

function string(value: unknown): string {
  if (typeof value !== "string") throw new Error("Expected a string");
  return value;
}

function number(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value))
    throw new Error("Expected a finite number");
  return value;
}

function readLocation(value: unknown): Location {
  const location = object(value);
  return {
    socket: string(location.socket),
    session: string(location.session),
    window: string(location.window),
    pane: string(location.pane),
    server: location.server === undefined ? undefined : string(location.server),
    scope: location.scope === undefined ? undefined : string(location.scope),
    process_id:
      location.process_id === undefined
        ? undefined
        : number(location.process_id),
    process_started:
      location.process_started === undefined
        ? undefined
        : string(location.process_started),
  };
}

const execute = promisify(execFile);
const connections = new Map<string, Connection>();

async function command(socket: string, ...args: string[]): Promise<string> {
  const result = await execute("@tmux@", ["-S", socket, ...args], {
    encoding: "utf8",
    timeout: 2000,
    maxBuffer: 1024 * 1024,
  });
  return result.stdout.trimEnd();
}

async function validate(location: Location): Promise<void> {
  if (
    !location.socket ||
    !/^\$\d+$/.test(location.session) ||
    !/^@\d+$/.test(location.window) ||
    !/^%\d+$/.test(location.pane)
  ) {
    throw new Error("Agent has no valid tmux location");
  }
  const rows = await command(
    location.socket,
    "list-panes",
    "-s",
    "-t",
    location.session,
    "-F",
    "#{session_id}\t#{window_id}\t#{pane_id}",
  );
  if (
    !rows
      .split("\n")
      .includes(`${location.session}\t${location.window}\t${location.pane}`)
  ) {
    throw new Error("The agent pane is no longer in its registered session");
  }
  if (location.scope) {
    const current = (await panes(location.socket)).find(
      (pane) =>
        pane.pane === location.pane && pane.session === location.session,
    );
    if (!current || current.scope !== location.scope || current.dead) {
      throw new Error("The registered tmux session has ended");
    }
    if (
      !location.process_id ||
      current.owner?.pid !== location.process_id ||
      current.owner.started !== location.process_started
    ) {
      throw new Error("This pane no longer belongs to the registered CLI");
    }
    const states = await observe([{ id: current.owner.id, location }]);
    if (states[current.owner.id] !== true)
      throw new Error("The registered CLI is no longer available");
  }
}

async function panes(socket: string): Promise<Pane[]> {
  const info = await stat(socket);
  const output = await command(
    socket,
    "list-panes",
    "-a",
    "-F",
    "#{pid}\t#{start_time}\t#{session_id}\t#{session_created}\t#{window_id}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{session_name}\t#{@agent_hub_owner}",
  );
  return output
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [
        pid,
        started,
        session,
        created,
        window,
        pane,
        panePid,
        dead,
        name,
        owner,
      ] = line.split("\t");
      const server = `${socket}:${info.ino}:${pid}:${started}`;
      const parsedOwner = owner ? object(JSON.parse(owner)) : null;
      return {
        socket,
        server,
        scope: `${server}:${session}:${created}`,
        session,
        window,
        pane,
        pane_pid: Number(panePid),
        dead: dead === "1",
        name,
        owner: parsedOwner
          ? {
              id: string(parsedOwner.id),
              pid: number(parsedOwner.pid),
              started: string(parsedOwner.started),
              at: number(parsedOwner.at),
            }
          : null,
      };
    });
}

async function processes() {
  const { stdout } = await execute(
    "/bin/ps",
    ["-axo", "pid=,ppid=,lstart=,args="],
    {
      encoding: "utf8",
      timeout: 1500,
      maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, LC_ALL: "C" },
    },
  );
  const result = new Map<number, ProcessInfo>();
  for (const line of stdout.split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.{24})\s+(.+)$/);
    if (match) {
      const [, pid, parent, started, args] = match;
      result.set(Number(pid), {
        pid: Number(pid),
        parent: Number(parent),
        started,
        args,
      });
    }
  }
  return result;
}

function ancestry(
  processes: Map<number, ProcessInfo>,
  pid: number,
): ProcessInfo[] {
  const chain: ProcessInfo[] = [];
  const seen = new Set<number>();
  while (pid > 1 && !seen.has(pid)) {
    seen.add(pid);
    const item = processes.get(pid);
    if (!item) break;
    chain.push(item);
    pid = item.parent;
  }
  return chain;
}

async function register(request: Registration): Promise<Location> {
  const current = await location();
  const chain = ancestry(await processes(), process.ppid);
  const patterns: Record<string, RegExp | undefined> = {
    codex: /(?:^|\/)\.?codex(?:[\s/.-]|$)|@openai\/codex\//,
    claude: /(?:^|\/)\.?claude(?:[\s/.-]|$)|@anthropic-ai\/claude-code\//,
    pi: /(?:dotfiles-pi|pi-coding-agent)\/.*(?:cli|index)\.(?:js|mjs)/,
    antigravity: /(?:^|\/)antigravity(?:[\s/.-]|$)/,
  };
  const pattern = patterns[request.client];
  const owner = chain.find((item) => {
    const [executable, entrypoint] = item.args.split(/\s+/, 2);
    const name = executable.split("/").at(-1);
    if (/^(?:ba|z|da)?sh$/.test(name ?? "")) return false;
    return pattern?.test(name === "node" ? (entrypoint ?? "") : executable);
  });
  if (!owner) return current;
  if (request.parent !== null) {
    return {
      ...current,
      process_id: owner.pid,
      process_started: owner.started,
    };
  }
  if (!current.pane) return current;
  const pane = (await panes(current.socket)).find(
    (pane) => pane.pane === current.pane && pane.session === current.session,
  );
  if (!pane || pane.dead) return current;
  const paneIndex = chain.findIndex((item) => item.pid === pane.pane_pid);
  if (paneIndex < 0 || !chain.slice(0, paneIndex + 1).includes(owner))
    return current;
  const id = `${request.client}:${request.session_id}`;
  if (
    pane.owner &&
    (pane.owner.at > request.at ||
      (pane.owner.id !== id && request.event !== "SessionStart"))
  )
    return current;
  const identity = {
    id,
    pid: owner.pid,
    started: owner.started,
    at: request.at,
  };
  if (request.event === "SessionEnd") {
    if (pane.owner?.id === id && pane.owner.pid === owner.pid) {
      await command(
        current.socket,
        "set-option",
        "-pu",
        "-t",
        current.pane,
        "@agent_hub_owner",
      );
    }
  } else {
    await command(
      current.socket,
      "set-option",
      "-p",
      "-t",
      current.pane,
      "@agent_hub_owner",
      JSON.stringify(identity),
    );
  }
  return { ...current, process_id: owner.pid, process_started: owner.started };
}

async function observe(
  agents: { id: string; location: Location; parent?: string | null }[],
): Promise<Record<string, boolean | null>> {
  const processMap = await processes();
  const sockets = new Map<string, Pane[] | null>();
  const states: Record<string, boolean | null> = {};
  for (const agent of agents) {
    const target = agent.location;
    if (agent.parent != null) {
      states[agent.id] = Boolean(
        target.process_id &&
        target.process_started &&
        processMap.get(target.process_id)?.started === target.process_started,
      );
      continue;
    }
    if (!target?.socket || !target.scope || !target.process_id) {
      states[agent.id] = false;
      continue;
    }
    if (!sockets.has(target.socket)) {
      try {
        sockets.set(target.socket, await panes(target.socket));
      } catch (error) {
        sockets.set(
          target.socket,
          error instanceof Error && "code" in error && error.code === "ENOENT"
            ? []
            : null,
        );
      }
    }
    const rows = sockets.get(target.socket);
    if (rows == null) {
      states[agent.id] = null;
      continue;
    }
    const pane = rows.find(
      (pane) => pane.pane === target.pane && pane.scope === target.scope,
    );
    const process = processMap.get(target.process_id);
    states[agent.id] = Boolean(
      pane &&
      !pane.dead &&
      pane.owner?.id === agent.id &&
      pane.owner.pid === target.process_id &&
      pane.owner.started === target.process_started &&
      process?.started === target.process_started &&
      ancestry(processMap, target.process_id).some(
        (item) => item.pid === pane.pane_pid,
      ),
    );
  }
  return states;
}

async function location(): Promise<Location> {
  if (!process.env.TMUX || !process.env.TMUX_PANE) {
    return { socket: "", session: "", window: "", pane: "" };
  }
  const parts = process.env.TMUX.split(",");
  const socket = parts.slice(0, -2).join(",");
  const session = `$${parts.at(-1)}`;
  const pane = process.env.TMUX_PANE;
  const row = (await panes(socket)).find(
    (item) => item.pane === pane && item.session === session,
  );
  if (!row) {
    throw new Error("Cannot identify the agent's original tmux session");
  }
  return {
    socket,
    session: row.session,
    window: row.window,
    pane: row.pane,
    server: row.server,
    scope: row.scope,
  };
}

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
        const marker = `@agent_hub_client_${pid}`;
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
            tty,
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
    ]) {
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
        const target: Registration = {
          client: string(request.client),
          session_id: string(request.session_id),
          parent: request.parent == null ? null : string(request.parent),
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
