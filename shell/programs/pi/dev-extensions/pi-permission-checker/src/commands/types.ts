// Command-analyzer interface. Each analyzer maps an argv to the file accesses it
// performs and any embedded/nested commands that must be analyzed recursively.

import type { PathAccess } from "../types.ts";

/** A nested command to analyze: either an already-tokenized argv or a raw shell script. */
export interface Nested {
  argv?: string[];
  script?: string;
}

export interface AnalyzeResult {
  pathAccesses: PathAccess[];
  nested: Nested[];
  /** Set when the command is a search (grep/find/rg) so the evaluator can apply its filter. */
  search?: { recursive: boolean };
  /** Set when the command runs code that can't be statically analyzed (python -c, eval, make). */
  opaque?: boolean;
}

export interface CommandAnalyzer {
  /** Command base names this analyzer handles. */
  names: string[];
  analyze(argv: string[], cwd: string): AnalyzeResult;
}
