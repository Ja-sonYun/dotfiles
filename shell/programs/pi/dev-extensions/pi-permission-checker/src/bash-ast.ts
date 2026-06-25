// Bash parsing via web-tree-sitter (WASM). Extracts argv command units and
// file-redirection accesses. Fails closed (ok: false) when parsing is unavailable
// or the command does not parse cleanly.

import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Language, Parser } from "web-tree-sitter";
import type { CommandUnit, PathAccess } from "./types.ts";

export interface ParsedBash {
  ok: boolean;
  units: CommandUnit[];
  redirects: PathAccess[];
}

/** Walk up from this module looking for a node_modules-hosted file. */
function locate(rel: string): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  for (let k = 0; k < 6; k++) {
    const p = resolve(dir, "node_modules", rel);
    if (existsSync(p)) return p;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  try {
    return createRequire(import.meta.url).resolve(rel);
  } catch {
    return rel;
  }
}

let parserPromise: Promise<Parser | null> | null = null;

async function getParser(): Promise<Parser | null> {
  if (parserPromise) return parserPromise;
  parserPromise = (async () => {
    try {
      const webTsWasm = locate("web-tree-sitter/web-tree-sitter.wasm");
      await Parser.init({ locateFile: () => webTsWasm });
      const bash = await Language.load(
        locate("tree-sitter-bash/tree-sitter-bash.wasm"),
      );
      const parser = new Parser();
      parser.setLanguage(bash);
      return parser;
    } catch {
      return null;
    }
  })();
  return parserPromise;
}

/** True once we know whether the parser could initialise (for tests / diagnostics). */
export async function parserAvailable(): Promise<boolean> {
  return (await getParser()) !== null;
}

interface AstNode {
  type: string;
  text: string;
  hasError: boolean;
  startIndex: number;
  endIndex: number;
  namedChildren: AstNode[];
  childForFieldName(name: string): AstNode | null;
  descendantsOfType(types: string | string[]): AstNode[];
}

const SKIP_IN_COMMAND = new Set([
  "variable_assignment",
  "file_redirect",
  "heredoc_redirect",
  "herestring_redirect",
  "regex",
]);

function tokenText(node: AstNode): string {
  switch (node.type) {
    case "raw_string":
      return node.text.slice(1, -1);
    case "string": {
      let t = node.text;
      if (t.startsWith('"') && t.endsWith('"')) t = t.slice(1, -1);
      return t;
    }
    case "command_name":
      return node.namedChildren.length
        ? tokenText(node.namedChildren[0])
        : node.text;
    case "concatenation":
      return node.namedChildren.length
        ? node.namedChildren.map(tokenText).join("")
        : node.text;
    default:
      return node.text;
  }
}

function commandArgv(cmd: AstNode): string[] {
  const argv: string[] = [];
  for (const child of cmd.namedChildren) {
    if (child.type === "command_name") argv.push(tokenText(child));
    else if (!SKIP_IN_COMMAND.has(child.type)) argv.push(tokenText(child));
  }
  return argv;
}

function extractRedirects(root: AstNode): PathAccess[] {
  const out: PathAccess[] = [];
  for (const r of root.descendantsOfType("file_redirect")) {
    const dest =
      r.childForFieldName("destination") ??
      r.namedChildren[r.namedChildren.length - 1];
    if (!dest) continue;
    const path = tokenText(dest);
    if (path === "" || /^\d+$/.test(path) || path === "-") continue; // fd dup / close
    out.push({ kind: r.text.includes(">") ? "write" : "read", path });
  }
  return out;
}

/** Parse a bash command into argv units (incl. those inside $()/<()) plus redirect accesses. */
export async function parseBash(command: string): Promise<ParsedBash> {
  const parser = await getParser();
  if (!parser) return { ok: false, units: [], redirects: [] };
  let tree;
  try {
    tree = parser.parse(command);
  } catch {
    return { ok: false, units: [], redirects: [] };
  }
  // tree-sitter trees hold WASM-side memory; always release it before returning.
  try {
    const root = tree?.rootNode as AstNode | undefined;
    if (!root || root.hasError) return { ok: false, units: [], redirects: [] };

    const units: CommandUnit[] = [];
    for (const cmd of root.descendantsOfType("command")) {
      const argv = commandArgv(cmd);
      if (argv.length)
        units.push({ argv, range: [cmd.startIndex, cmd.endIndex] });
    }
    return { ok: true, units, redirects: extractRedirects(root) };
  } finally {
    tree?.delete();
  }
}
