// Loads config.json and parses permission rule strings.

import { readFileSync } from "node:fs";
import type { Config, PermissionMode, Rule } from "./types.ts";

const TOOL_NAMES = new Set([
  "bash",
  "read",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
]);

/** Split a whitespace-separated argv pattern into tokens. */
export function tokenizeArgvPattern(s: string): string[] {
  return s
    .trim()
    .split(/\s+/)
    .filter((t) => t.length > 0);
}

/** Parse one rule source string into a structured Rule, or undefined if malformed. */
export function parseRule(src: string): Rule | undefined {
  const s = src.trim();
  if (s.startsWith("Path(") && s.endsWith(")")) {
    return { kind: "path", glob: s.slice("Path(".length, -1) };
  }
  if (s.startsWith("ArgRegex(") && s.endsWith(")")) {
    const source = s.slice("ArgRegex(".length, -1);
    try {
      return { kind: "argRegex", source, re: new RegExp(source) };
    } catch {
      return undefined;
    }
  }
  const paren = /^([A-Za-z_]+)\((.*)\)$/.exec(s);
  if (paren) {
    const tool = paren[1];
    const inner = paren[2];
    // Only the intercepted tools can be matched; reject misspelled/unknown tools
    // so a typo like `bsh(...)` is dropped loudly rather than silently never matching.
    if (!TOOL_NAMES.has(tool)) return undefined;
    if (inner.startsWith("argv:")) {
      // argv-token matching only applies to bash; `read(argv:...)` etc. is meaningless.
      if (tool !== "bash") return undefined;
      return {
        kind: "bashArgv",
        tokens: tokenizeArgvPattern(inner.slice("argv:".length)),
      };
    }
    return { kind: "toolGlob", tool, glob: inner };
  }
  if (TOOL_NAMES.has(s)) return { kind: "tool", tool: s };
  return undefined;
}

function parseRuleList(
  list: unknown,
  allowArgRegex: boolean,
  invalid: string[],
): Rule[] {
  if (!Array.isArray(list)) return [];
  const out: Rule[] = [];
  for (const item of list) {
    if (typeof item !== "string") continue;
    const rule = parseRule(item);
    if (!rule) {
      invalid.push(item); // typo / unknown tool — dropped, surfaced to the user
      continue;
    }
    // ArgRegex is deny-only — ignore it in allow/ask so a regex can never grant access.
    if (rule.kind === "argRegex" && !allowArgRegex) {
      invalid.push(`${item} (ArgRegex is deny-only)`);
      continue;
    }
    out.push(rule);
  }
  return out;
}

function isMode(v: unknown): v is PermissionMode {
  return v === "allow" || v === "ask" || v === "deny";
}

/** Build a Config from a parsed JSON object (defaults applied). */
export function buildConfig(raw: unknown): Config {
  const obj = (raw && typeof raw === "object" ? raw : {}) as Record<
    string,
    unknown
  >;
  const perms = (
    obj.permissions && typeof obj.permissions === "object"
      ? obj.permissions
      : {}
  ) as Record<string, unknown>;

  const invalidRules: string[] = [];
  const deny = parseRuleList(perms.deny, true, invalidRules);
  const allow = parseRuleList(perms.allow, false, invalidRules);
  const ask = parseRuleList(perms.ask, false, invalidRules);

  const wildcardableRaw = Array.isArray(obj.wildcardable)
    ? obj.wildcardable
    : [];
  const wildcardable: string[][] = [];
  for (const w of wildcardableRaw) {
    if (typeof w !== "string") continue;
    const rule = parseRule(w);
    if (rule && rule.kind === "bashArgv") wildcardable.push(rule.tokens);
    else
      invalidRules.push(`${w} (wildcardable must be a bash(argv:...) pattern)`);
  }

  return {
    debug: obj.debug === true,
    defaultMode: isMode(obj.defaultMode) ? obj.defaultMode : "ask",
    allow,
    ask,
    deny,
    wildcardable,
    denyPathGlobs: deny
      .filter((r) => r.kind === "path")
      .map((r) => (r as { glob: string }).glob),
    invalidRules,
  };
}

export interface LoadedConfig {
  config: Config;
  /** Set when config.json exists but could not be read/parsed (rules silently dropped otherwise). */
  error?: string;
}

/** Load config.json. A missing file yields defaults; a present-but-invalid file reports an error. */
export function loadConfig(path: string): LoadedConfig {
  let text: string;
  try {
    text = readFileSync(path, "utf-8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT")
      return { config: buildConfig({}) };
    return {
      config: buildConfig({}),
      error: `cannot read config.json: ${(e as Error).message}`,
    };
  }
  try {
    return { config: buildConfig(JSON.parse(text)) };
  } catch (e) {
    return {
      config: buildConfig({}),
      error: `invalid config.json: ${(e as Error).message}`,
    };
  }
}
