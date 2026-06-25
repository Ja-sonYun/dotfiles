// In-memory session decisions (allow and deny). Not persisted: cleared on
// session_start / session_shutdown. Deny entries are matched permissively (any
// overlap denies); allow entries must fully cover a request.

import {
  containingDir,
  gitRoot,
  isWithin,
  realPath,
  resolvePath,
  tokenGlobMatch,
} from "./paths.ts";
import type { AccessKind, Request } from "./types.ts";

type SessionEffect = "allow" | "deny";

export type SessionEntry =
  | { decision: SessionEffect; scope: "tool"; tool: string }
  | { decision: SessionEffect; scope: "command"; command: string }
  | {
      decision: SessionEffect;
      scope: "path";
      pathKind: "file" | "dir" | "gitroot";
      base: string;
      access: AccessKind;
    }
  | { decision: SessionEffect; scope: "wildcard"; tokens: string[] };

// read < edit < write: a higher-ranked approval covers lower-ranked accesses.
const ACCESS_RANK: Record<AccessKind, number> = { read: 0, edit: 1, write: 2 };

let entries: SessionEntry[] = [];

export function clear(): void {
  entries = [];
}

export function add(entry: SessionEntry): void {
  entries.push(entry);
}

export function all(): SessionEntry[] {
  return entries.slice();
}

/** Resolve the canonical base path for a session path-scope entry (realpath-normalized). */
export function pathBase(
  path: string,
  cwd: string,
  kind: "file" | "dir" | "gitroot",
): string {
  const real = realPath(resolvePath(path, cwd));
  if (kind === "file") return real;
  const dir = containingDir(real);
  if (kind === "dir") return dir;
  return gitRoot(dir) ?? dir;
}

// `strict` is used for ALLOW coverage: the canonical (realpath) location must be inside the
// approved base, so a symlink under the base can't escape it. DENY stays lenient (matches the
// lexical or canonical path) so a symlinked route to a denied target is still caught.
function pathEntryCovers(
  entry: Extract<SessionEntry, { scope: "path" }>,
  path: string,
  cwd: string,
  strict: boolean,
): boolean {
  const abs = resolvePath(path, cwd);
  const real = realPath(abs);
  if (entry.pathKind === "file") {
    return strict
      ? real === entry.base
      : abs === entry.base || real === entry.base;
  }
  return strict
    ? isWithin(entry.base, real)
    : isWithin(entry.base, abs) || isWithin(entry.base, real);
}

/** True if any session deny entry overlaps the request. */
export function matchesDeny(req: Request): boolean {
  for (const e of entries) {
    if (e.decision !== "deny") continue;
    if (e.scope === "tool" && e.tool === req.tool) return true;
    if (
      e.scope === "command" &&
      req.commandText !== undefined &&
      e.command === req.commandText
    ) {
      return true;
    }
    if (
      e.scope === "wildcard" &&
      req.units.some((u) => tokenGlobMatch(e.tokens, u.argv))
    ) {
      return true;
    }
    if (
      e.scope === "path" &&
      req.accesses.some((a) => pathEntryCovers(e, a.path, req.cwd, false))
    ) {
      return true;
    }
  }
  return false;
}

/** True if session allow entries fully cover the request. */
export function matchesAllow(req: Request): boolean {
  // Whole-tool / whole-command approvals cover the entire request.
  for (const e of entries) {
    if (e.decision === "allow" && e.scope === "tool" && e.tool === req.tool)
      return true;
  }
  if (req.commandText !== undefined) {
    for (const e of entries) {
      if (
        e.decision === "allow" &&
        e.scope === "command" &&
        e.command === req.commandText
      ) {
        return true;
      }
    }
  }

  // Granular approvals: EVERY present dimension (command units AND file accesses)
  // must be fully covered. This prevents a path-only approval from authorizing an
  // unrelated command unit (e.g. `cat approved.txt && curl evil`), where access
  // extraction is intentionally incomplete for unknown commands.
  if (req.units.length === 0 && req.accesses.length === 0) return false;

  const wc = entries.filter(
    (e): e is Extract<SessionEntry, { scope: "wildcard" }> =>
      e.decision === "allow" && e.scope === "wildcard",
  );
  const pe = entries.filter(
    (e): e is Extract<SessionEntry, { scope: "path" }> =>
      e.decision === "allow" && e.scope === "path",
  );

  const unitsCovered =
    req.units.length === 0 ||
    (wc.length > 0 &&
      req.units.every((u) => wc.some((e) => tokenGlobMatch(e.tokens, u.argv))));
  const accessesCovered =
    req.accesses.length === 0 ||
    (pe.length > 0 &&
      req.accesses.every((a) =>
        pe.some(
          (e) =>
            ACCESS_RANK[e.access] >= ACCESS_RANK[a.kind] &&
            pathEntryCovers(e, a.path, req.cwd, true),
        ),
      ));

  return unitsCovered && accessesCovered;
}

export function describeEntry(e: SessionEntry): string {
  const verb = e.decision === "allow" ? "allow" : "deny";
  switch (e.scope) {
    case "tool":
      return `${verb} tool ${e.tool}`;
    case "command":
      return `${verb} command "${e.command}"`;
    case "wildcard":
      return `${verb} wildcard \`${e.tokens.join(" ")}\``;
    case "path":
      return `${verb} ${e.access} ${e.pathKind} ${e.base}`;
  }
}
