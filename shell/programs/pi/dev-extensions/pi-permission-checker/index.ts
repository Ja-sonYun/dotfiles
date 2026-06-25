// pi-permission-checker — enforce Claude Code-style permission rules in pi.
//
// Intercepts tool calls (bash/read/edit/write/grep/find/ls), evaluates them against
// config.json rules plus in-memory session decisions, and allows / asks / denies.
// Bash commands are parsed with tree-sitter and analyzed recursively (xargs, find
// -exec, sh -c, ...) so file-access and command rules apply to what actually runs.

import type {
  ExtensionAPI,
  ToolCallEvent,
} from "@earendil-works/pi-coding-agent";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { analyzeBashCommand } from "./src/commands/index.ts";
import { loadConfig } from "./src/config.ts";
import { evaluate } from "./src/evaluator.ts";
import { explainScripts } from "./src/explain.ts";
import { askUser } from "./src/prompt.ts";
import * as session from "./src/session.ts";
import type { Config, PathAccess, Request } from "./src/types.ts";

const PERM_TOOLS = new Set([
  "bash",
  "read",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
]);
const CONFIG_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "config.json",
);

interface BuiltRequest {
  req?: Request;
  parseError?: boolean;
  commandText?: string;
  invalidReason?: string;
}

function optionalPath(input: Record<string, unknown>): string {
  const p = input.path;
  return typeof p === "string" && p.trim() !== "" ? p : ".";
}

async function buildRequest(
  event: ToolCallEvent,
  cwd: string,
): Promise<BuiltRequest> {
  const tool = event.toolName;
  const input = event.input as Record<string, unknown>;

  if (tool === "bash") {
    const command = typeof input.command === "string" ? input.command : "";
    if (command.trim() === "")
      return { invalidReason: "bash called without a command string" };
    const a = await analyzeBashCommand(command, cwd);
    // Fail closed when the command (or a nested sh -c payload) could not be fully analyzed.
    if (!a.parseOk || a.incomplete)
      return { parseError: true, commandText: command };
    return {
      req: {
        tool,
        commandText: command,
        units: a.units,
        accesses: a.accesses,
        cwd,
        isSearch: a.isSearch,
        searchRecursive: a.searchRecursive,
        opaque: a.opaque,
        explainTargets: a.explainTargets,
      },
    };
  }

  const accesses: PathAccess[] = [];
  let isSearch = false;
  let searchRecursive = false;
  switch (tool) {
    case "read":
    case "edit":
    case "write": {
      const p = input.path;
      if (typeof p !== "string" || p.trim() === "") {
        return { invalidReason: `${tool} called without a valid path` };
      }
      accesses.push({ kind: tool, path: p }); // toolName is exactly the access kind here
      break;
    }
    case "ls":
      accesses.push({ kind: "read", path: optionalPath(input) });
      break;
    case "grep":
    case "find":
      accesses.push({ kind: "read", path: optionalPath(input) });
      isSearch = true;
      searchRecursive = true;
      break;
  }
  return {
    req: {
      tool,
      units: [],
      accesses,
      cwd,
      isSearch,
      searchRecursive,
      opaque: false,
    },
  };
}

export default function (pi: ExtensionAPI): void {
  let loaded = loadConfig(CONFIG_PATH);
  let config: Config = loaded.config;
  let configError = loaded.error;
  const parseFailures = new Map<string, number>();

  pi.on("session_start", (_event, ctx) => {
    session.clear();
    parseFailures.clear();
    if (configError) {
      ctx.ui.notify(
        `permission-checker: ${configError} — enforcing safe defaults (no allow rules).`,
        "error",
      );
    }
    if (config.invalidRules.length > 0) {
      ctx.ui.notify(
        `permission-checker: ignored ${config.invalidRules.length} invalid rule(s): ${config.invalidRules.join("; ")}`,
        "warning",
      );
    }
  });
  pi.on("session_shutdown", () => {
    session.clear();
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!PERM_TOOLS.has(event.toolName)) return {};

    // Fail closed: any unexpected error in the permission path blocks the call
    // rather than letting the tool run unchecked.
    try {
      const built = await buildRequest(event, ctx.cwd);

      if (built.invalidReason) {
        return { block: true, reason: `Blocked: ${built.invalidReason}.` };
      }

      if (built.parseError) {
        const key = built.commandText ?? "";
        if (parseFailures.size > 1000 && !parseFailures.has(key))
          parseFailures.clear(); // bound memory
        const n = (parseFailures.get(key) ?? 0) + 1;
        parseFailures.set(key, n);
        if (n <= 3) {
          return {
            block: true,
            reason:
              `This bash command could not be fully analyzed for a safety check (attempt ${n}/3). ` +
              `Rewrite it as one or more simpler commands and avoid unusual quoting or syntax.`,
          };
        }
        return {
          block: true,
          reason:
            "This bash command could not be analyzed for a safety check and is blocked. Run a simpler command instead.",
        };
      }

      const req = built.req!;
      const res = evaluate(req, config);
      if (config.debug) {
        ctx.ui.notify(
          `[permission-checker] ${event.toolName} -> ${res.decision} (${res.matched ?? "-"})`,
          "info",
        );
      }

      if (res.decision === "allow") return {};
      if (res.decision === "deny")
        return {
          block: true,
          reason: res.reason || "Denied by permission policy.",
        };

      // ask
      if (!ctx.hasUI) {
        return {
          block: true,
          reason:
            `Permission required but no interactive UI is available. ${res.reason}`.trim(),
        };
      }
      // For commands that run code (python -c, scripts, eval/sh -c), ask the current model in a
      // separate context to explain what it does, and show that in the prompt. Advisory only.
      let explanation: string | undefined;
      if (req.explainTargets && req.explainTargets.length > 0) {
        ctx.ui.setWorkingMessage("Analyzing script…");
        try {
          explanation = await explainScripts(
            req.explainTargets,
            ctx,
            config.denyPathGlobs,
          );
        } finally {
          ctx.ui.setWorkingMessage();
        }
      }
      return await askUser(ctx.ui, req, config, explanation);
    } catch (e) {
      // Non-Error throwables (null/undefined/string) must not break fail-closed.
      const msg = e instanceof Error ? e.message : String(e);
      return {
        block: true,
        reason: `Permission check failed; blocking. ${msg}`.trim(),
      };
    }
  });

  pi.registerCommand("permission-checker", {
    description: "Permission checker: show | reload | approvals | path <p>",
    handler: async (args, ctx) => {
      const parts = args
        .trim()
        .split(/\s+/)
        .filter((p) => p.length > 0);
      const sub = parts[0] ?? "show";

      if (sub === "reload") {
        loaded = loadConfig(CONFIG_PATH);
        config = loaded.config;
        configError = loaded.error;
        ctx.ui.notify(
          configError
            ? `permission-checker: reload failed — ${configError}`
            : "permission-checker: config reloaded",
          configError ? "error" : "info",
        );
        return;
      }
      if (sub === "approvals") {
        const list = session.all();
        ctx.ui.notify(
          list.length
            ? list.map(session.describeEntry).join("\n")
            : "No session decisions.",
          "info",
        );
        return;
      }
      if (sub === "path") {
        const p = parts.slice(1).join(" ");
        const req: Request = {
          tool: "read",
          units: [],
          accesses: [{ kind: "read", path: p }],
          cwd: ctx.cwd,
          isSearch: false,
          searchRecursive: false,
          opaque: false,
        };
        const res = evaluate(req, config);
        ctx.ui.notify(
          `${p} -> ${res.decision}${res.matched ? ` (${res.matched})` : ""}`,
          "info",
        );
        return;
      }

      ctx.ui.notify(
        `defaultMode=${config.defaultMode} allow=${config.allow.length} ask=${config.ask.length} ` +
          `deny=${config.deny.length} wildcardable=${config.wildcardable.length} session=${session.all().length}`,
        "info",
      );
    },
  });
}
