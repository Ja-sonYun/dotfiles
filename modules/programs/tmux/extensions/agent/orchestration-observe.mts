import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import { promisify } from "node:util";

export interface Location {
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
  server: string;
  scope: string;
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

export interface Registration {
  client: string;
  session_id: string;
  parent: string | null;
  identity: "root" | "child" | "unknown";
  event: string;
  at: number;
}

export function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("Expected a JSON object");
  return value as Record<string, unknown>;
}

export function string(value: unknown): string {
  if (typeof value !== "string") throw new Error("Expected a string");
  return value;
}

export function number(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value))
    throw new Error("Expected a finite number");
  return value;
}

export function readLocation(value: unknown): Location {
  const location = object(value);
  return {
    socket: string(location.socket),
    session: string(location.session),
    window: string(location.window),
    pane: string(location.pane),
    ...(location.server === undefined
      ? {}
      : { server: string(location.server) }),
    ...(location.scope === undefined ? {} : { scope: string(location.scope) }),
    ...(location.process_id === undefined
      ? {}
      : { process_id: number(location.process_id) }),
    ...(location.process_started === undefined
      ? {}
      : { process_started: string(location.process_started) }),
  };
}

const execute = promisify(execFile);

export async function command(
  socket: string,
  ...args: string[]
): Promise<string> {
  const result = await execute("@tmux@", ["-S", socket, ...args], {
    encoding: "utf8",
    timeout: 2000,
    maxBuffer: 1024 * 1024,
  });
  return result.stdout.trimEnd();
}

export async function validate(location: Location): Promise<void> {
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

export async function panes(socket: string): Promise<Pane[]> {
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
        session: string(session),
        window: string(window),
        pane: string(pane),
        pane_pid: Number(panePid),
        dead: dead === "1",
        name: string(name),
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
        started: string(started),
        args: string(args),
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

export async function register(request: Registration): Promise<Location> {
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
    if (!executable) return false;
    const name = executable.split("/").at(-1);
    if (/^(?:ba|z|da)?sh$/.test(name ?? "")) return false;
    return pattern?.test(name === "node" ? (entrypoint ?? "") : executable);
  });
  if (!owner) return current;
  if (request.identity === "child") {
    return {
      ...current,
      pane: request.parent === null ? "" : current.pane,
      window: request.parent === null ? "" : current.window,
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
    request.identity === "unknown" &&
    (pane.owner?.id !== id ||
      pane.owner.pid !== owner.pid ||
      pane.owner.started !== owner.started)
  )
    return current;
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
    if (
      pane.owner?.id === id &&
      pane.owner.pid === owner.pid &&
      pane.owner.started === owner.started
    ) {
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

export async function observe(
  agents: { id: string; location: Location; parent?: string | null }[],
): Promise<Record<string, boolean | null>> {
  const processMap = await processes();
  const sockets = new Map<string, Pane[] | null>();
  const states: Record<string, boolean | null> = {};
  for (const agent of agents) {
    const target = agent.location;
    if (agent.parent != null || (!target.pane && target.process_id)) {
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

export async function location(): Promise<Location> {
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
