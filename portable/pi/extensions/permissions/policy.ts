import { existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import { opendir } from "node:fs/promises";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import {
  dirname,
  isAbsolute,
  join,
  matchesGlob,
  relative,
  resolve,
  sep,
} from "node:path";
import { commandOperands, type ShellAnalysis } from "./bash.ts";

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
  projectRead?: boolean;
  requestScopeExempt?: boolean;
  binaries?: {
    name: string;
    directories: string[];
    args: string[];
    reason: string;
    identity?: string;
    path?: string;
  }[];
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
    ...resourceTools,
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

function isProjectPath(path: string, projectRoot: string | undefined): boolean {
  if (!projectRoot) return false;
  // Resolve links before applying the project's standing read authorization.
  const pathFromRoot = relative(canonical(projectRoot), canonical(path));
  return (
    !isAbsolute(pathFromRoot) &&
    pathFromRoot !== ".." &&
    !pathFromRoot.startsWith(`..${sep}`)
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
  fallback: Decision = access === "read" && policy.defaultRead
    ? "allow"
    : "ask",
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
  return strongest(decisions, fallback);
}

export async function assessSearch(
  policy: Policy,
  call: Call,
  actor: Actor,
  search: string,
  projectRoot?: string,
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
  let projectRead =
    isProjectPath(actor.cwd, projectRoot) &&
    isProjectPath(
      absolute(
        typeof call.input.path === "string" ? call.input.path : ".",
        actor.cwd,
      ),
      projectRoot,
    );
  for (const file of files.split("\0").filter(Boolean)) {
    const decision = fileDecision(policy, file, actor.cwd, "read");
    decisions.push(decision);
    projectRead &&=
      decision === "allow" &&
      isProjectPath(absolute(file, actor.cwd), projectRoot);
    if (decision !== "allow") reasons.push(`${decision}: search reads ${file}`);
  }
  return { decision: strongest(decisions, "allow"), reasons, projectRead };
}

const resourceTools = [
  "list_mcp_resources",
  "list_mcp_resource_templates",
  "read_mcp_resource",
];

function fileArguments(args: (string | null)[]): string[] {
  const paths: string[] = [];
  let positional = false;
  for (const arg of args) {
    if (!arg) continue;
    if (positional || !arg.startsWith("-")) paths.push(arg);
    else if (arg === "--") positional = true;
    else if (arg.startsWith("--") && arg.includes("=")) {
      const value = arg.slice(arg.indexOf("=") + 1);
      if (value) paths.push(value);
    }
  }
  return paths;
}

async function inspectSearchDirectory(
  search: string,
  cwd: string,
  path: string,
  readPath: (path: string) => void,
  signal?: AbortSignal,
) {
  const child = spawn(search, ["--files", "--null", "--", path], {
    cwd,
    signal,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let diagnostic = false;
  child.stderr.on("data", () => {
    diagnostic = true;
  });
  const completion = new Promise<void>((done, fail) => {
    child.on("error", fail);
    child.on("close", (code) => {
      if (!diagnostic && (code === 0 || code === 1)) done();
      else fail(new Error("Search file enumeration failed"));
    });
  });
  const inspect = async () => {
    let pending = "";
    const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
    const directories = new Set([path]);
    for await (const chunk of child.stdout) {
      const paths = (pending + decoder.decode(chunk, { stream: true })).split(
        "\0",
      );
      pending = paths.pop()!;
      for (const file of paths) {
        for (
          let dir = dirname(file);
          !directories.has(dir);
          dir = dirname(dir)
        ) {
          directories.add(dir);
          readPath(dir);
        }
        readPath(file);
      }
    }
    if (pending + decoder.decode())
      throw new Error("Incomplete search file listing");
  };
  try {
    await Promise.all([completion, inspect()]);
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill();
  }
}

export async function assessBash(
  policy: Policy,
  call: Call,
  actor: Actor,
  shell: ShellAnalysis,
  projectRoot: string,
  search: string,
  signal?: AbortSignal,
): Promise<Assessment> {
  if (actor.mode === "plan" || !shell.steps?.length)
    return assess(policy, call, actor, shell, projectRoot);
  const steps = shell.steps;
  const reasons = new Set<string>();
  const binaries: NonNullable<Assessment["binaries"]> = [];
  let decision: Decision = "allow";
  let projectRead = isProjectPath(actor.cwd, projectRoot);
  const add = (value: Decision, reason: string) => {
    decision = strongest([decision, value]);
    reasons.add(`${value}: ${reason}`);
  };
  const readPath = (path: string): Decision => {
    const access = fileDecision(policy, path, actor.cwd, "read");
    if (access !== "allow") add(access, "read " + path);
    if (!isProjectPath(path, projectRoot)) {
      add("ask", "read outside project: " + path);
    }
    return access;
  };

  const readDirectory = async (
    path: string,
    recursive: boolean,
    hidden: boolean,
  ) => {
    const pending = [path];
    while (pending.length) {
      const directory = pending.pop()!;
      for await (const entry of await opendir(directory)) {
        signal?.throwIfAborted();
        if (!hidden && entry.name.startsWith(".")) continue;
        const child = join(directory, entry.name);
        if (readPath(child) !== "deny" && recursive && entry.isDirectory())
          pending.push(child);
      }
    }
  };
  let success = [actor.cwd];
  let failure: string[] = [];
  let directories = success;
  let skippedSuccess: string[] = [];
  let skippedFailure: string[] = [];
  let uncertainContext = false;
  for (const [i, step] of steps.entries()) {
    const [name, ...args] = step.args;
    if (step.operator !== "|") {
      directories =
        step.operator === "&&"
          ? success
          : step.operator === "||"
            ? failure
            : [...new Set([...success, ...failure])];
      skippedSuccess = step.operator === "||" ? success : [];
      skippedFailure = step.operator === "&&" ? failure : [];
    }
    if (directories.length > 32)
      return {
        decision: "deny",
        reasons: ["Too many possible working directories to inspect"],
      };
    if (step.unresolved) {
      add("ask", "Unresolved shell step " + (i + 1));
      for (const cwd of directories) {
        const part = assess(
          policy,
          call,
          actor,
          step.unresolved,
          projectRoot,
          [],
          cwd,
        );
        decision = strongest([decision, part.decision]);
        for (const reason of part.reasons) reasons.add(reason);
      }
      uncertainContext = true;
      success = [...new Set([...directories, ...skippedSuccess])];
      failure = [...new Set([...directories, ...skippedFailure])];
      continue;
    }
    const stdin = step.operator === "|" || step.redirectedStdin === true;
    const inputs = commandOperands(step.args, stdin);
    const isCd = name === "cd";
    if (
      isCd &&
      (!inputs || step.operator === "|" || steps[i + 1]?.operator === "|")
    )
      uncertainContext = true;
    if (
      /^(?:source|\.|exec|builtin|command|eval|set|shopt|hash|unset|export|declare|alias|unalias|enable|pushd|popd|read|readarray|mapfile|let|typeset|readonly|local|trap|getopts|printf)$/.test(
        name,
      ) &&
      i + 1 < steps.length
    )
      uncertainContext = true;
    if (uncertainContext)
      add("ask", "Shell execution context could not be determined");
    const matched = policy.commands.rules.filter((rule) =>
      rule.prefix.every(
        (token, pos) =>
          step.args[pos] === token ||
          (pos === 0 &&
            rule.decision !== "allow" &&
            name.split("/").at(-1) === token),
      ),
    );
    const commandReason = `command ${i + 1} ${JSON.stringify(step.args)}`;
    const commandDecision = strongest(
      matched.map((rule) => rule.decision),
      inputs ? "allow" : "ask",
    );
    add(commandDecision, commandReason);
    const supported =
      /^(?:awk|sed|grep|rg|sort|uniq|cut|ls|du|stat|file|unzip|head|tail|wc|cat|cd)$/;
    const opaque = shell.uncertain.includes(
      "Indirect execution or changed shell context: " + name,
    );
    const unknown =
      !inputs &&
      !supported.test(name) &&
      (!opaque || name.includes("/")) &&
      !policy.commands.rules.some(
        (rule) => rule.prefix[0] === name.split("/").at(-1),
      );
    if (!inputs) {
      projectRead = false;
      if (supported.test(name) || (opaque && !unknown))
        add("ask", "Inspect arguments of " + name);
    }
    if (
      !uncertainContext &&
      unknown &&
      commandDecision === "ask" &&
      directories.length > 0
    ) {
      binaries.push({
        name,
        directories,
        args,
        reason: "ask: " + commandReason,
      });
    }
    const destinations = new Set<string>();
    for (const cwd of directories) {
      if (!isProjectPath(cwd, projectRoot)) {
        projectRead = false;
        if (inputs) add("ask", "Working directory outside project: " + cwd);
      }
      const files = [...step.files];
      if (name === "tee") {
        for (const path of args.filter((arg) => !arg.startsWith("-")))
          files.push({ path, access: "write" });
      }
      for (const path of inputs?.outputs ?? [])
        files.push({ path, access: "write" });
      for (const file of files) {
        const path = resolve(cwd, file.path);
        if (file.access === "read") readPath(path);
        else {
          projectRead = false;
          add(
            strongest(["ask", fileDecision(policy, path, actor.cwd, "write")]),
            "write " + path,
          );
        }
      }
      if (step.args.some((arg) => arg.split("/").includes("..")))
        add("ask", "Parent directory traversal");
      for (const operand of inputs?.paths ?? fileArguments(args)) {
        const path = resolve(cwd, operand);
        if (!inputs) {
          const access = strongest([
            fileDecision(policy, path, actor.cwd, "read", "allow"),
            fileDecision(policy, path, actor.cwd, "write", "allow"),
          ]);
          if (access !== "allow")
            add(access, "Protected file argument: " + path);
          continue;
        }
        if (isCd) destinations.add(path);
        if (readPath(path) === "deny") continue;
        if (inputs.kind === "archive") {
          if (/[*?\\[\]]/.test(operand))
            add("ask", "Archive pattern: " + operand);
          if (!statSync(path, { throwIfNoEntry: false })?.isFile()) {
            readPath(path + ".zip");
            readPath(path + ".ZIP");
          }
        }
        if (statSync(path, { throwIfNoEntry: false })?.isDirectory()) {
          if (inputs.kind === "directory" || inputs.kind === "tree") {
            if (name === "rg")
              await inspectSearchDirectory(search, cwd, path, readPath, signal);
            else
              await readDirectory(
                path,
                inputs.kind === "tree",
                name !== "ls" ||
                  args.some((arg) => /^-[alh]*a[alh]*$/.test(arg)),
              );
          }
        }
      }
    }
    const next =
      isCd && inputs && step.operator !== "|" && steps[i + 1]?.operator !== "|"
        ? destinations
        : directories;
    success = [...new Set([...next, ...skippedSuccess])];
    failure = [...new Set([...directories, ...skippedFailure])];
  }
  return {
    decision,
    reasons: [...reasons],
    projectRead: projectRead && decision === "allow",
    binaries,
  };
}

export function assess(
  policy: Policy,
  call: Call,
  actor: Actor,
  shell?: ShellAnalysis,
  projectRoot?: string,
  allModesServers: string[] = [],
  shellCwd = actor.cwd,
): Assessment {
  const reasons: string[] = [];
  const decisions: Decision[] = [];
  let projectRead = false;
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
    if (resourceTools.includes(call.toolName)) {
      return call.input.server === server
        ? [{ server, tool: call.toolName, rules }]
        : [];
    }
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
  const singleMcp = mcp.length === 1 ? mcp[0] : undefined;
  const mcpDecision = singleMcp
    ? strongest(
        [singleMcp.rules.default, singleMcp.rules.tools[singleMcp.tool]].filter(
          (value): value is Decision => !!value,
        ),
      )
    : "ask";
  const readonlyMcp =
    singleMcp !== undefined &&
    (policy.mcp_readonly_tools[singleMcp.server] ?? []).includes(
      singleMcp.tool,
    );
  const readTools = ["read", "grep", "find", "ls"];
  if (
    actor.mode === "plan" &&
    ![...readTools, "codemode", "tool_search"].includes(call.toolName) &&
    !readonlyMcp &&
    !resourceTools.includes(call.toolName) &&
    !(
      singleMcp &&
      mcpDecision === "allow" &&
      allModesServers.includes(singleMcp.server)
    )
  ) {
    return {
      decision: "deny",
      reasons: ["Read-only agents cannot execute this tool"],
    };
  }

  if ([...readTools, "write", "edit"].includes(call.toolName)) {
    const access = readTools.includes(call.toolName) ? "read" : "write";
    const path = typeof call.input.path === "string" ? call.input.path : ".";
    const fileAccess = fileDecision(policy, path, actor.cwd, access);
    projectRead =
      access === "read" &&
      fileAccess === "allow" &&
      isProjectPath(actor.cwd, projectRoot) &&
      isProjectPath(absolute(path, actor.cwd), projectRoot);
    if (projectRead && call.toolName === "ls") {
      // Pi's ls stats each entry and follows links when checking directory types.
      // https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/ls.ts
      projectRead = readdirSync(absolute(path, actor.cwd)).every((entry) =>
        isProjectPath(join(absolute(path, actor.cwd), entry), projectRoot),
      );
    }
    add(
      fileAccess,
      `${access} ${path} -> ${canonical(absolute(path, actor.cwd))}`,
    );
  } else if (call.toolName === "bash" && shell) {
    if (projectRoot) add("ask", "Shell context could not be determined");
    for (const [index, args] of shell.commands.entries()) {
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
        !shell.stdinGreps?.includes(index) &&
        (!policy.defaultRead ||
          policy.files.rules.some((rule) => rule.read !== "allow"))
      ) {
        add(
          "ask",
          "Bash search file scope is unverified; use the grep tool for checked file selection",
        );
      }
      for (const arg of fileArguments(args.slice(1))) {
        const operand = absolute(arg, shellCwd);
        if (fileDecision(policy, operand, actor.cwd, "read") === "deny") {
          add("deny", `Denied file argument: ${arg}`);
        }
        if (
          !["cat", "head", "tail", "ls", "grep", "rg"].includes(
            args[0] ?? "",
          ) &&
          fileDecision(policy, operand, actor.cwd, "write") === "deny"
        ) {
          add("deny", `Command may modify a write-protected file: ${arg}`);
        }
      }
    }
    for (const file of shell.files)
      add(
        strongest([
          file.access === "write" ? "ask" : "allow",
          fileDecision(
            policy,
            absolute(file.path, shellCwd),
            actor.cwd,
            file.access,
          ),
        ]),
        `${file.access} ${file.path}`,
      );
    for (const reason of shell.uncertain) add("ask", reason);
  } else if (singleMcp !== undefined) {
    const { server, tool } = singleMcp;
    add(mcpDecision, `MCP ${server}/${tool}`);
  } else if (mcp.length > 1) {
    add("deny", "Ambiguous MCP namespace");
  } else if (["codemode", "tool_search"].includes(call.toolName)) {
    add(
      "allow",
      "Tool discovery/orchestration; nested executions are checked separately",
    );
  }
  const decision = strongest(decisions);
  return {
    decision,
    reasons,
    projectRead: projectRead && decision === "allow",
    requestScopeExempt: singleMcp !== undefined && decision === "allow",
  };
}
