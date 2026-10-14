import { existsSync, realpathSync } from "node:fs";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import { dirname, join, matchesGlob, resolve } from "node:path";
import type { ShellAnalysis } from "./bash.ts";

export type Decision = "allow" | "ask" | "deny";
export interface Policy {
  commands: { rules: { prefix: string[]; decision: Decision }[] };
  files: { rules: { path: string; read: Decision; write: Decision }[] };
  mcp: Record<
    string,
    { default: Decision | null; tools: Record<string, Decision> }
  >;
  mcp_readonly_tools: Record<string, string[]>;
  defaultRead: boolean;
}
export interface Call {
  toolCallId?: string;
  toolName: string;
  input: Record<string, unknown>;
  parentToolCallId?: string;
}
export interface Actor {
  cwd: string;
  name: string;
  mode: "default" | "plan";
  task: string;
}
export interface Assessment {
  decision: Decision;
  reasons: string[];
}

export function mcpName(server: string, tool: string): string {
  // Match Pi 1.1's public MCP tool naming, including its length limit.
  // https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/src/extensions/mcp/tools.ts
  const name = `mcp__${server}__${tool}`.replace(/[^A-Za-z0-9_]/g, "_");
  if (name.length <= 64) return name;
  const hash = createHash("sha256")
    .update(`${server}\0${tool}`)
    .digest("hex")
    .slice(0, 8);
  return `${name.slice(0, 55)}_${hash}`;
}

export function readonlyTools(policy: Policy): string[] {
  return [
    "read",
    "grep",
    "find",
    "ls",
    "codemode",
    "tool_search",
    ...Object.entries(policy.mcp_readonly_tools).flatMap(([server, tools]) =>
      tools.map((tool) => mcpName(server, tool)),
    ),
  ];
}

export function strongest(
  values: Decision[],
  fallback: Decision = "ask",
): Decision {
  if (values.includes("deny")) return "deny";
  if (values.includes("ask")) return "ask";
  return values.includes("allow") ? "allow" : fallback;
}

export function canonical(path: string): string {
  try {
    return realpathSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    const parent = dirname(path);
    if (parent === path) throw error;
    return join(canonical(parent), path.slice(parent.length));
  }
}

export function absolute(path: string, cwd: string): string {
  return resolve(
    cwd,
    path === "~"
      ? homedir()
      : path.startsWith("~/")
        ? join(homedir(), path.slice(2))
        : path,
  );
}

export function normalizeFileCall(call: Call, cwd: string): void {
  if (!["read", "write", "edit", "grep", "find", "ls"].includes(call.toolName))
    return;
  if (typeof call.input.path !== "string") return;
  // Use Pi's path spellings before both policy evaluation and execution.
  // https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/src/core/tools/path-utils.ts
  let path = call.input.path
    .replace(/[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g, " ")
    .replace(/^@/, "");
  if (path.startsWith("file://")) path = fileURLToPath(path);
  path = absolute(path, cwd);
  if (call.toolName === "read" && !existsSync(path)) {
    const variants = [
      path.replace(/ (AM|PM)\./gi, "\u202F$1."),
      path.normalize("NFD"),
      path.replace(/'/g, "\u2019"),
      path.normalize("NFD").replace(/'/g, "\u2019"),
    ];
    path = variants.find((variant) => existsSync(variant)) ?? path;
  }
  call.input.path = path;
}

export function fileDecision(
  policy: Policy,
  path: string,
  cwd: string,
  access: "read" | "write",
): Decision {
  const lexical = absolute(path, cwd);
  const actual = canonical(lexical);
  const decisions: Decision[] = [];
  for (const rule of policy.files.rules) {
    const pattern = rule.path.startsWith("**/")
      ? rule.path
      : absolute(rule.path, cwd);
    if (
      [lexical, actual].some(
        (value) =>
          matchesGlob(value, pattern) ||
          (pattern.endsWith("/**") && value === pattern.slice(0, -3)),
      )
    ) {
      decisions.push(rule.read === "deny" ? "deny" : rule[access]);
    }
  }
  return strongest(
    decisions,
    access === "read" && policy.defaultRead ? "allow" : "ask",
  );
}

export async function assessSearch(
  policy: Policy,
  call: Call,
  actor: Actor,
  search: string,
): Promise<Assessment> {
  // Match Pi's hidden-file, glob, ignore, and symlink selection without reading contents.
  // https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/src/core/tools/grep.ts
  const args = ["--files", "--hidden", "--null"];
  if (typeof call.input.glob === "string" && call.input.glob)
    args.push("--glob", call.input.glob);
  args.push(
    "--",
    absolute(
      typeof call.input.path === "string" ? call.input.path : ".",
      actor.cwd,
    ),
  );
  const files = await new Promise<string>((resolve, reject) => {
    execFile(
      search,
      args,
      { cwd: actor.cwd, timeout: 30000, maxBuffer: 32 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error && !(error.code === 1 && !error.killed && !stderr))
          reject(error);
        else resolve(stdout);
      },
    );
  });
  const decisions: Decision[] = [];
  const reasons: string[] = [];
  for (const file of files.split("\0").filter(Boolean)) {
    const decision = fileDecision(policy, file, actor.cwd, "read");
    decisions.push(decision);
    if (decision !== "allow") reasons.push(`${decision}: search reads ${file}`);
  }
  return { decision: strongest(decisions, "allow"), reasons };
}

export function assess(
  policy: Policy,
  call: Call,
  actor: Actor,
  shell?: ShellAnalysis,
): Assessment {
  const reasons: string[] = [];
  const decisions: Decision[] = [];
  const add = (decision: Decision, reason: string) => {
    decisions.push(decision);
    reasons.push(`${decision}: ${reason}`);
  };
  const servers = new Set([
    ...Object.keys(policy.mcp),
    ...Object.keys(policy.mcp_readonly_tools),
  ]);
  const mcp = [...servers].flatMap((server) => {
    const rules = policy.mcp[server] ?? { default: null, tools: {} };
    const prefix = `mcp__${server.replace(/[^A-Za-z0-9_]/g, "_")}__`;
    const configured = [
      ...new Set([
        ...Object.keys(rules.tools),
        ...(policy.mcp_readonly_tools[server] ?? []),
      ]),
    ].filter((tool) => mcpName(server, tool) === call.toolName);
    return configured.length > 0
      ? configured.map((tool) => ({ server, tool, rules }))
      : call.toolName.startsWith(prefix)
        ? [{ server, tool: call.toolName.slice(prefix.length), rules }]
        : [];
  });
  const readonlyMcp =
    mcp.length === 1 &&
    (policy.mcp_readonly_tools[mcp[0].server] ?? []).includes(mcp[0].tool);
  const readTools = ["read", "grep", "find", "ls"];
  if (
    actor.mode === "plan" &&
    ![...readTools, "codemode", "tool_search"].includes(call.toolName) &&
    !readonlyMcp
  ) {
    return {
      decision: "deny",
      reasons: ["Read-only agents cannot execute this tool"],
    };
  }

  if ([...readTools, "write", "edit"].includes(call.toolName)) {
    const access = readTools.includes(call.toolName) ? "read" : "write";
    const path = typeof call.input.path === "string" ? call.input.path : ".";
    add(
      fileDecision(policy, path, actor.cwd, access),
      `${access} ${path} -> ${canonical(absolute(path, actor.cwd))}`,
    );
  } else if (call.toolName === "bash" && shell) {
    for (const args of shell.commands) {
      const matched = policy.commands.rules.filter((rule) =>
        rule.prefix.every(
          (token, i) =>
            args[i] === token ||
            (i === 0 &&
              rule.decision === "deny" &&
              args[i]?.split("/").at(-1) === token),
        ),
      );
      add(
        strongest(matched.map((rule) => rule.decision)),
        `command ${JSON.stringify(args)}`,
      );
      if (
        ["rg", "grep", "egrep", "fgrep", "rgrep"].includes(
          args[0]?.split("/").at(-1) ?? "",
        ) &&
        (!policy.defaultRead ||
          policy.files.rules.some((rule) => rule.read !== "allow"))
      ) {
        add(
          "ask",
          "Bash search file scope is unverified; use the grep tool for checked file selection",
        );
      }
      for (const arg of args.slice(1)) {
        if (
          arg &&
          !arg.startsWith("-") &&
          fileDecision(policy, arg, actor.cwd, "read") === "deny"
        ) {
          add("deny", `Denied file argument: ${arg}`);
        }
        if (
          arg &&
          !arg.startsWith("-") &&
          !["cat", "head", "tail", "ls", "grep", "rg"].includes(
            args[0] ?? "",
          ) &&
          fileDecision(policy, arg, actor.cwd, "write") === "deny"
        ) {
          add("deny", `Command may modify a write-protected file: ${arg}`);
        }
      }
    }
    for (const file of shell.files)
      add(
        fileDecision(policy, file.path, actor.cwd, file.access),
        `${file.access} ${file.path}`,
      );
    for (const reason of shell.uncertain) add("ask", reason);
  } else if (mcp.length === 1) {
    const { server, tool, rules } = mcp[0];
    add(
      strongest(
        [rules.default, rules.tools[tool]].filter((x): x is Decision => !!x),
      ),
      `MCP ${server}/${tool}`,
    );
  } else if (mcp.length > 1) {
    add("deny", "Ambiguous MCP namespace");
  } else if (["codemode", "tool_search"].includes(call.toolName)) {
    add(
      "allow",
      "Tool discovery/orchestration; nested executions are checked separately",
    );
  }
  return { decision: strongest(decisions), reasons };
}
