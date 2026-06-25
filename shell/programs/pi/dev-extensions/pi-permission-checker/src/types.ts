// Core types shared across the permission checker.

export type PermissionMode = "allow" | "ask" | "deny";

/** The kind of file access a request performs. `write` covers create/modify/delete. */
export type AccessKind = "read" | "edit" | "write";

export interface PathAccess {
  kind: AccessKind;
  /** Path exactly as written by the command/tool (may be relative or contain ~). */
  path: string;
}

/** One simple command's argv tokens (command name + arguments, quotes stripped). */
export interface CommandUnit {
  argv: string[];
  /** [start, end) offsets of this unit in the original command text. Set only for
   * top-level / command-substitution units (those parsed directly from the source);
   * units recovered by re-parsing a nested script (sh -c '...') have none. */
  range?: [number, number];
}

export type Decision = "allow" | "ask" | "deny";

/** A snippet of code a command will execute, surfaced for an AI explanation in the prompt. */
export interface ExplainTarget {
  /** Language hint: python | js | ts | ruby | perl | php | shell. */
  lang: string;
  /** Inline code text (python -c, node -e, eval/sh -c script), if known. */
  code?: string;
  /** Script file path to read from disk, if the code lives in a file. */
  path?: string;
}

/** Config rule after parsing its source string. */
export type Rule =
  | { kind: "tool"; tool: string } // `read`
  | { kind: "toolGlob"; tool: string; glob: string } // `bash(git status *)` / `edit(src/**)`
  | { kind: "bashArgv"; tokens: string[] } // `bash(argv:sed ** -i* **)`
  | { kind: "path"; glob: string } // `Path(**/.env*)`
  | { kind: "argRegex"; source: string; re: RegExp }; // `ArgRegex(...)` — deny only

export interface Config {
  debug: boolean;
  defaultMode: PermissionMode;
  allow: Rule[];
  ask: Rule[];
  deny: Rule[];
  /** Predefined wildcard argv patterns eligible for "allow `echo *` for this session". */
  wildcardable: string[][];
  /** Raw deny path globs, kept for building search-filter retry hints. */
  denyPathGlobs: string[];
  /** Rule strings that failed to parse (typos / unknown tools) and were dropped. */
  invalidRules: string[];
}

/** A request to evaluate, assembled from a tool_call event. */
export interface Request {
  tool: string;
  /** Raw bash command text (only for the bash tool). */
  commandText?: string;
  /** Parsed bash command units, including recursively-extracted nested commands. */
  units: CommandUnit[];
  /** File accesses extracted from the tool input or bash analysis. */
  accesses: PathAccess[];
  cwd: string;
  isSearch: boolean;
  searchRecursive: boolean;
  /** True when a bash unit runs code that can't be statically analyzed (forces ask). */
  opaque: boolean;
  /** Code snippets (inline / script files) this command runs, for an AI explanation. */
  explainTargets?: ExplainTarget[];
}

export interface EvalResult {
  decision: Decision;
  reason: string;
  /** The rule source string or scope that drove the decision (for debug). */
  matched?: string;
}
