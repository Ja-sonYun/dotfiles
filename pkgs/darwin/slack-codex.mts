import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { isRecord } from "./contracts.mjs";
import { start } from "./process.mjs";
import type { RunningProcess } from "./process.mjs";

// Keep policy checks available without granting data mutations.
const controlTools: Record<string, string[]> = {
  rules: ["rules_check"],
};

async function readonlyArgs(
  command: string,
  directory: string,
  signal: AbortSignal,
  log: (event: string, fields: Record<string, unknown>) => void,
): Promise<string[]> {
  type SettingValue =
    string | number | boolean | string[] | Map<string, SettingValue>;
  const settings = new Map<string, SettingValue>();
  function setting(
    keys: string[],
    value: string | number | boolean | string[],
  ): void {
    let table = settings;
    for (const [index, key] of keys.entries()) {
      if (index === keys.length - 1) {
        table.set(key, value);
      } else {
        const existing = table.get(key);
        const child =
          existing instanceof Map ? existing : new Map<string, SettingValue>();
        table.set(key, child);
        table = child;
      }
    }
  }
  function tomlValue(value: SettingValue): string {
    if (!(value instanceof Map)) return JSON.stringify(value);
    return `{${Array.from(value, ([key, child]) => `${JSON.stringify(key)}=${tomlValue(child)}`).join(",")}}`;
  }
  // A fresh profile cannot inherit unmanaged write grants under the same name.
  const profile = `slack-readonly-${randomUUID()}`;
  setting(["default_permissions"], profile);
  setting(["permissions", profile, "extends"], ":read-only");
  setting(["permissions", profile, "network", "enabled"], false);
  setting(["approval_policy"], "never");
  setting(["approvals_reviewer"], "user");
  setting(["web_search"], "live");

  signal.throwIfAborted();
  const server = start(
    directory,
    command,
    [
      "--config",
      'approval_policy="never"',
      "--config",
      'approvals_reviewer="user"',
      "app-server",
    ],
    {
      ...process.env,
      TYPESAFE_API_KEY: undefined,
      AI_AGENT_SUBAGENT: "1",
    },
    800,
    null,
  );
  const lines = createInterface({ input: server.child.stdout });
  let stage = "startup";
  let sequence = 0;
  const pending = new Map<
    number,
    {
      method: string;
      resolve(value: Record<string, unknown>): void;
      reject(error: Error): void;
    }
  >();
  let failure: Error | undefined;
  function fail(error: Error): void {
    failure = error;
    for (const request of pending.values()) request.reject(error);
    pending.clear();
  }
  const abort = () => {
    fail(new Error("Codex tool discovery was cancelled."));
    void server.stop().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  if (signal.aborted) abort();
  void server.done.then(
    () => fail(new Error("Codex tool discovery exited before completing.")),
    (error: unknown) =>
      fail(new Error("Codex tool discovery failed.", { cause: error })),
  );
  lines.on("line", (line) => {
    try {
      const message: unknown = JSON.parse(line);
      if (!isRecord(message))
        throw new Error("Invalid Codex discovery response.");
      if (typeof message.method === "string") {
        if (message.id !== undefined) {
          server.child.stdin.write(
            `${JSON.stringify({
              id: message.id,
              error: {
                code: -32601,
                message: "Tool discovery does not accept requests.",
              },
            })}\n`,
          );
        }
        return;
      }
      if (typeof message.id !== "number") return;
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.error) {
        const details = isRecord(message.error)
          ? [
              typeof message.error.code === "number"
                ? message.error.code
                : null,
              typeof message.error.message === "string"
                ? message.error.message
                : null,
            ]
              .filter((value) => value !== null)
              .join(": ")
          : "";
        request.reject(
          new Error(
            `Codex ${request.method} failed${details ? `: ${details}` : "."}`,
            {
              cause: isRecord(message.error)
                ? {
                    code:
                      typeof message.error.code === "number"
                        ? message.error.code
                        : null,
                    message:
                      typeof message.error.message === "string"
                        ? message.error.message
                        : null,
                  }
                : undefined,
            },
          ),
        );
      } else if (!isRecord(message.result)) {
        request.reject(
          new Error(
            `Codex ${request.method} returned an invalid result: expected an object.`,
          ),
        );
      } else {
        request.resolve(message.result);
      }
    } catch {
      fail(new Error("Invalid Codex discovery response."));
    }
  });
  function request(
    method: string,
    params: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    signal.throwIfAborted();
    if (failure) return Promise.reject(failure);
    stage = method;
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      pending.set(id, { method, resolve, reject });
      server.child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
    });
  }
  async function pages(method: string): Promise<Record<string, unknown>[]> {
    const result: Record<string, unknown>[] = [];
    let cursor: string | null = null;
    do {
      let page: Record<string, unknown>;
      for (let attempt = 1; ; attempt++) {
        const started = performance.now();
        try {
          page = await request(method, { limit: 100, cursor });
          if (method === "app/list")
            log("app_list_attempt", {
              attempt,
              status: "completed",
              elapsed_ms: performance.now() - started,
            });
          break;
        } catch (error) {
          if (method === "app/list")
            log("app_list_attempt", {
              attempt,
              status: signal.aborted ? "cancelled" : "failed",
              elapsed_ms: performance.now() - started,
            });
          signal.throwIfAborted();
          if (
            method !== "app/list" ||
            !(error instanceof Error) ||
            !isRecord(error.cause) ||
            error.cause.code !== -32603 ||
            error.cause.message !==
              "failed to list apps: Failed to send request"
          )
            throw error;
          if (attempt === 3)
            throw new Error(`${error.message} (after 3 attempts)`, {
              cause: error.cause,
            });
          await delay(attempt * 500, undefined, { signal });
        }
      }
      if (!Array.isArray(page.data) || !page.data.every(isRecord)) {
        throw new Error("Invalid Codex tool catalog.");
      }
      result.push(...page.data);
      if (page.nextCursor !== null && typeof page.nextCursor !== "string") {
        throw new Error("Invalid Codex tool catalog cursor.");
      }
      cursor = page.nextCursor;
    } while (cursor !== null);
    return result;
  }
  // CLI tables are merged, so close existing per-tool and per-account grants too.
  function restrictExisting(value: unknown, keys: string[]): void {
    if (!isRecord(value)) return;
    for (const [key, child] of Object.entries(value)) {
      if (key === "tools" && isRecord(child)) {
        for (const name of Object.keys(child)) {
          setting([...keys, key, name, "enabled"], false);
        }
      }
      restrictExisting(child, [...keys, key]);
    }
  }
  try {
    await request("initialize", {
      clientInfo: { name: "slack-readonly", version: "1" },
      capabilities: { experimentalApi: true },
    });
    server.child.stdin.write(`${JSON.stringify({ method: "initialized" })}\n`);
    const configuration = await request("config/read", {
      includeLayers: false,
      cwd: directory,
    });
    if (!isRecord(configuration.config))
      throw new Error("Invalid Codex configuration response.");
    // Retain existing read exclusions while reducing every write grant to read.
    const filesystem = new Map<
      string,
      { keys: string[]; access: "read" | "deny" }
    >();
    function restrictFiles(value: unknown, keys: string[]): void {
      if (!isRecord(value)) throw new Error("Invalid Codex filesystem policy.");
      for (const [key, access] of Object.entries(value)) {
        if (keys.length === 0 && key === "glob_scan_max_depth") {
          if (access === null) continue;
          if (
            typeof access !== "number" ||
            !Number.isSafeInteger(access) ||
            access < 0
          ) {
            throw new Error("Invalid Codex filesystem glob scan depth.");
          }
          setting(["permissions", profile, "filesystem", key], access);
          continue;
        }
        const target = [...keys, key];
        if (isRecord(access)) {
          restrictFiles(access, target);
        } else if (
          access === "write" ||
          access === "read" ||
          access === "deny"
        ) {
          const id = JSON.stringify(target);
          filesystem.set(id, {
            keys: target,
            access:
              access === "deny" || filesystem.get(id)?.access === "deny"
                ? "deny"
                : "read",
          });
        } else {
          throw new Error("Unsupported Codex filesystem permission.");
        }
      }
    }
    const profiles: Record<string, unknown> = isRecord(
      configuration.config.permissions,
    )
      ? configuration.config.permissions
      : {};
    const visited = new Set<string>();
    function inheritFiles(name: unknown): void {
      if (name == null || name === ":read-only" || name === ":workspace")
        return;
      if (
        typeof name !== "string" ||
        visited.has(name) ||
        !isRecord(profiles[name])
      ) {
        throw new Error(
          "Cannot preserve the selected Codex permission profile.",
        );
      }
      visited.add(name);
      const inherited = profiles[name];
      inheritFiles(inherited.extends);
      if (inherited.filesystem !== undefined)
        restrictFiles(inherited.filesystem, []);
    }
    inheritFiles(configuration.config.default_permissions);
    for (const entry of filesystem.values()) {
      setting(
        ["permissions", profile, "filesystem", ...entry.keys],
        entry.access,
      );
    }
    restrictExisting(configuration.config.apps, ["apps"]);
    setting(["apps", "_default", "enabled"], false);
    if (isRecord(configuration.config.apps)) {
      for (const id of Object.keys(configuration.config.apps)) {
        if (id !== "_default") setting(["apps", id, "enabled"], false);
      }
    }

    const [apps, servers] = await Promise.all([
      pages("app/list"),
      pages("mcpServerStatus/list"),
    ]);
    for (const app of apps) {
      if (typeof app.id !== "string" || typeof app.name !== "string") {
        throw new Error("Invalid Codex app catalog.");
      }
      const enabled =
        ["slack", "notion", "gmail"].includes(app.name.toLowerCase()) &&
        app.isEnabled === true &&
        app.isAccessible === true;
      setting(["apps", app.id, "enabled"], enabled);
      if (!enabled) continue;
      setting(["apps", app.id, "default_tools_enabled"], false);
      const details = await request("app/read", {
        appIds: [app.id],
        includeTools: true,
      });
      if (!Array.isArray(details.apps))
        throw new Error("Invalid Codex app tools.");
      const detail = details.apps.find(
        (item: unknown) => isRecord(item) && item.id === app.id,
      );
      if (!isRecord(detail) || !Array.isArray(detail.toolSummaries)) {
        throw new Error("Codex did not provide the app's tool permissions.");
      }
      for (const tool of detail.toolSummaries) {
        if (!isRecord(tool) || typeof tool.name !== "string") {
          throw new Error("Invalid Codex app tool.");
        }
        setting(
          ["apps", app.id, "tools", tool.name, "enabled"],
          tool.isReadOnly === true && tool.isEnabled === true,
        );
      }
    }

    const configuredServers = isRecord(configuration.config.mcp_servers)
      ? configuration.config.mcp_servers
      : {};
    for (const name of Object.keys(configuredServers)) {
      if (
        !servers.some(
          (server) => server.name === name && server.pluginId == null,
        )
      ) {
        setting(["mcp_servers", name, "enabled"], false);
      }
    }
    for (const server of servers) {
      if (typeof server.name !== "string" || !isRecord(server.tools)) {
        throw new Error("Invalid Codex MCP tool catalog.");
      }
      // Apps use their own policy; only configure registered MCP servers here.
      if (server.pluginId == null && !(server.name in configuredServers)) {
        if (server.name === "codex_apps") continue;
        throw new Error("Cannot restrict an unrecognized Codex MCP server.");
      }
      if (server.pluginId != null && typeof server.pluginId !== "string") {
        throw new Error("Invalid Codex MCP plugin identity.");
      }
      const keys =
        typeof server.pluginId === "string"
          ? ["plugins", server.pluginId, "mcp_servers", server.name]
          : ["mcp_servers", server.name];
      const enabled: string[] = [];
      for (const [name, tool] of Object.entries(server.tools)) {
        const control =
          server.pluginId == null &&
          controlTools[server.name]?.includes(name) === true;
        if (
          control ||
          (isRecord(tool) &&
            isRecord(tool.annotations) &&
            tool.annotations.readOnlyHint === true)
        ) {
          enabled.push(name);
          if (control)
            setting([...keys, "tools", name, "approval_mode"], "approve");
        }
      }
      setting([...keys, "enabled_tools"], enabled);
    }
    // CLI keys are split on dots; quoted dynamic keys belong inside TOML values.
    return Array.from(settings).flatMap(([key, value]) => [
      "--config",
      `${key}=${tomlValue(value)}`,
    ]);
  } catch (error) {
    const logger = process.env.SLACK_CODEX_LOG_COMMAND;
    if (logger && !signal.aborted) {
      const cause =
        error instanceof Error && error.cause instanceof Error
          ? error.cause
          : error;
      // Keep diagnostic delivery independent of the review's failure handling.
      try {
        execFile(
          logger,
          [
            "slack-codex",
            "error",
            "discovery_failed",
            `stage=${stage}`,
            `error=${cause instanceof Error ? cause.message : "Unknown discovery failure."}`,
          ],
          { timeout: 1000 },
          () => {},
        );
      } catch {}
    }
    throw error;
  } finally {
    signal.removeEventListener("abort", abort);
    lines.close();
    await server.stop();
  }
}

export async function generateWithCodex(
  command: string,
  directory: string,
  model: string | undefined,
  prompt: string,
  schema: object,
  signal: AbortSignal,
  reasoningEffort?: string,
  serviceTier?: string,
): Promise<unknown> {
  let timeout = AbortSignal.timeout(120_000);
  let deadline = AbortSignal.any([signal, timeout]);
  const runId = randomUUID();
  const prefix = path.join(directory, `codex-${runId}`);
  const started = performance.now();
  const log = (event: string, fields: Record<string, unknown>) => {
    const logger = process.env.SLACK_CODEX_LOG_COMMAND;
    if (!logger) return;
    try {
      execFile(
        logger,
        [
          "slack-codex",
          "info",
          event,
          `run_id=${runId}`,
          ...Object.entries(fields)
            .filter(([, value]) => value !== undefined)
            .map(([key, value]) => `${key}=${String(value)}`),
        ],
        { timeout: 1000 },
        () => {},
      );
    } catch {}
  };
  let phase = "discovery";
  let phaseStarted = started;
  let status = "failed";
  let incomplete = false;
  let observedEvents = false;
  let buffer = "";
  let dropping = false;
  const calls = new Map<
    string,
    {
      type: string;
      server: string | undefined;
      tool: string | undefined;
      started?: number;
      ended: boolean;
    }
  >();
  const observeLine = (line: string) => {
    try {
      const event: unknown = JSON.parse(line);
      if (!isRecord(event) || typeof event.type !== "string") {
        incomplete = true;
        return;
      }
      observedEvents = true;
      if (
        !["item.started", "item.updated", "item.completed"].includes(event.type)
      )
        return;
      const item = event.item;
      if (
        !isRecord(item) ||
        typeof item.id !== "string" ||
        typeof item.type !== "string"
      ) {
        incomplete = true;
        return;
      }
      if (
        !["mcp_tool_call", "command_execution", "web_search"].includes(
          item.type,
        )
      )
        return;
      let call = calls.get(item.id);
      if (!call) {
        call = {
          type: item.type,
          server: typeof item.server === "string" ? item.server : undefined,
          tool: typeof item.tool === "string" ? item.tool : undefined,
          ended: false,
        };
        calls.set(item.id, call);
      }
      if (call.ended) return;
      if (event.type === "item.started" && call.started === undefined) {
        call.started = performance.now();
        log("tool_call", {
          call_id: item.id,
          type: call.type,
          server: call.server,
          tool: call.tool,
          status: "in_progress",
        });
      }
      if (event.type === "item.completed") {
        call.ended = true;
        const outcome =
          item.status === "failed" ||
          (item.type === "command_execution" &&
            typeof item.exit_code === "number" &&
            item.exit_code !== 0)
            ? "failed"
            : item.status === "completed" || item.type === "web_search"
              ? "completed"
              : "unknown";
        if (outcome === "unknown") incomplete = true;
        log("tool_call", {
          call_id: item.id,
          type: call.type,
          server: call.server,
          tool: call.tool,
          status: outcome,
          elapsed_ms:
            call.started === undefined
              ? null
              : performance.now() - call.started,
        });
      }
    } catch {
      incomplete = true;
    }
  };
  const observe = (chunk: string) => {
    let offset = 0;
    while (offset < chunk.length) {
      const newline = chunk.indexOf("\n", offset);
      const end = newline < 0 ? chunk.length : newline;
      const part = chunk.slice(offset, end);
      if (!dropping) {
        if (Buffer.byteLength(buffer) + Buffer.byteLength(part) > 1024 * 1024) {
          buffer = "";
          dropping = true;
          incomplete = true;
        } else buffer += part;
      }
      if (newline < 0) break;
      if (!dropping && buffer.trim()) observeLine(buffer);
      buffer = "";
      dropping = false;
      offset = newline + 1;
    }
  };
  const schemaFile = `${prefix}.schema.json`;
  const resultFile = `${prefix}.result.json`;
  let agent: RunningProcess | undefined;
  const abort = () => {
    void agent?.stop().catch(() => {});
  };
  try {
    const args = await readonlyArgs(command, directory, deadline, log);
    deadline.throwIfAborted();
    log("phase", {
      phase,
      status: "completed",
      elapsed_ms: performance.now() - phaseStarted,
    });
    phase = "generation";
    phaseStarted = performance.now();
    timeout = AbortSignal.timeout(100_000);
    deadline = AbortSignal.any([signal, timeout]);
    await writeFile(schemaFile, JSON.stringify(schema), {
      mode: 0o600,
      flag: "wx",
    });
    deadline.throwIfAborted();
    agent = start(
      directory,
      command,
      [
        ...args,
        ...(reasoningEffort
          ? [
              "--config",
              `model_reasoning_effort=${JSON.stringify(reasoningEffort)}`,
            ]
          : []),
        ...(serviceTier
          ? ["--config", `service_tier=${JSON.stringify(serviceTier)}`]
          : []),
        ...(serviceTier === "fast"
          ? ["--config", "features.fast_mode=true"]
          : []),
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--ephemeral",
        "--output-schema",
        schemaFile,
        "--output-last-message",
        resultFile,
        ...(model ? ["--model", model] : []),
        "-",
      ],
      { ...process.env, TYPESAFE_API_KEY: undefined, AI_AGENT_SUBAGENT: "1" },
      800,
      null,
    );
    agent.child.stdout.on("data", observe);
    deadline.addEventListener("abort", abort, { once: true });
    if (deadline.aborted) abort();
    agent.child.stdin.end(prompt);
    await agent.done;
    deadline.throwIfAborted();
    if ((await stat(resultFile)).size > 1024 * 1024) {
      throw new Error("Codex response exceeded 1 MiB.");
    }
    const result: unknown = JSON.parse(await readFile(resultFile, "utf8"));
    status = "completed";
    return result;
  } catch (error) {
    signal.throwIfAborted();
    if (timeout.aborted) throw new Error("Codex response timed out.");
    throw error;
  } finally {
    if (signal.aborted) status = "cancelled";
    else if (timeout.aborted) status = "timed_out";
    deadline.removeEventListener("abort", abort);
    try {
      await agent?.stop();
    } finally {
      agent?.child.stdout.off("data", observe);
      if (buffer || dropping || (agent && !observedEvents)) incomplete = true;
      for (const [id, call] of calls) {
        if (!call.ended) {
          incomplete = true;
          log("tool_call", {
            call_id: id,
            type: call.type,
            server: call.server,
            tool: call.tool,
            status: status === "completed" ? "unknown" : status,
            elapsed_ms:
              call.started === undefined
                ? null
                : performance.now() - call.started,
          });
        }
      }
      log("phase", {
        phase,
        status,
        elapsed_ms: performance.now() - phaseStarted,
      });
      log("run_completed", {
        status,
        elapsed_ms: performance.now() - started,
        tool_calls: calls.size,
        observation_incomplete: incomplete,
      });
      await Promise.all([
        rm(schemaFile, { force: true }),
        rm(resultFile, { force: true }),
      ]);
    }
  }
}
