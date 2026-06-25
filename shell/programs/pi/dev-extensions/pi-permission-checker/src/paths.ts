// Path resolution, git-root detection, and glob / token-glob matching.

import { existsSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve, sep } from "node:path";

/** Expand a leading ~ and resolve to a canonical absolute path (normalizing `..`). Never throws. */
export function resolvePath(p: string, cwd: string): string {
  let raw = p;
  if (raw === "~") raw = homedir();
  else if (raw.startsWith("~/")) raw = homedir() + raw.slice(1);
  // resolve() normalizes `.`/`..` even for absolute inputs, so /a/../b -> /b
  // before any glob/deny matching can be fooled by traversal segments.
  return resolve(cwd, raw);
}

/** Resolve symlinks where possible, falling back to the resolved absolute path. */
export function realPath(abs: string): string {
  try {
    return realpathSync(abs);
  } catch {
    return abs;
  }
}

/** Walk upward from a directory looking for a `.git` entry. Returns the repo root or undefined. */
export function gitRoot(startDir: string): string | undefined {
  let dir = startDir;
  for (;;) {
    if (existsSync(resolve(dir, ".git"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

/** Directory containing the path (its parent if it's a file, itself if it's a dir). */
export function containingDir(abs: string): string {
  try {
    if (statSync(abs).isDirectory()) return abs;
  } catch {
    // path may not exist yet (e.g. write target) — use its parent.
  }
  return dirname(abs);
}

function escapeRegexChar(c: string): string {
  return /[.+^${}()|[\]\\\/]/.test(c) ? "\\" + c : c;
}

/** Path-aware glob: `**` crosses `/`, `*` and `?` stay within a segment. `**\/` matches zero+ dirs. */
export function pathGlobToRegExp(glob: string): RegExp {
  let re = "";
  let i = 0;
  while (i < glob.length) {
    if (glob.startsWith("**/", i)) {
      re += "(?:.*/)?";
      i += 3;
    } else if (glob.startsWith("**", i)) {
      re += ".*";
      i += 2;
    } else if (glob[i] === "*") {
      re += "[^/]*";
      i += 1;
    } else if (glob[i] === "?") {
      re += "[^/]";
      i += 1;
    } else {
      re += escapeRegexChar(glob[i]);
      i += 1;
    }
  }
  return new RegExp("^" + re + "$");
}

/** Simple glob for command text / within-token matching: `*` = any chars, `?` = one char. */
export function simpleGlobToRegExp(glob: string): RegExp {
  let re = "";
  for (const c of glob) {
    if (c === "*") re += ".*";
    else if (c === "?") re += ".";
    else re += escapeRegexChar(c);
  }
  return new RegExp("^" + re + "$");
}

/** True if a Path(glob) rule matches a path, testing the literal, resolved, and realpath forms. */
export function matchPathGlob(
  glob: string,
  path: string,
  cwd: string,
): boolean {
  const re = pathGlobToRegExp(glob);
  if (re.test(path)) return true;
  const abs = resolvePath(path, cwd);
  if (re.test(abs)) return true;
  const real = realPath(abs);
  return real !== abs && re.test(real);
}

function withinTokenMatch(patTok: string, tok: string): boolean {
  if (!patTok.includes("*") && !patTok.includes("?")) return patTok === tok;
  return simpleGlobToRegExp(patTok).test(tok);
}

/**
 * Token-level glob over argv. Pattern tokens:
 *  - `**` matches zero or more argv tokens
 *  - `*` matches exactly one argv token
 *  - otherwise the token is matched with within-token glob (`*`/`?`)
 */
export function tokenGlobMatch(pattern: string[], argv: string[]): boolean {
  const memo = new Map<string, boolean>();
  function go(i: number, j: number): boolean {
    const key = i + "," + j;
    const cached = memo.get(key);
    if (cached !== undefined) return cached;
    let res: boolean;
    if (i === pattern.length) {
      res = j === argv.length;
    } else if (pattern[i] === "**") {
      res = go(i + 1, j) || (j < argv.length && go(i, j + 1));
    } else if (j >= argv.length) {
      res = false;
    } else if (pattern[i] === "*") {
      res = go(i + 1, j + 1);
    } else {
      res = withinTokenMatch(pattern[i], argv[j]) && go(i + 1, j + 1);
    }
    memo.set(key, res);
    return res;
  }
  return go(0, 0);
}

/** True if `child` is the same path as `base` or nested under it. */
export function isWithin(base: string, child: string): boolean {
  if (child === base) return true;
  const b = base.endsWith(sep) ? base : base + sep;
  return child.startsWith(b);
}
