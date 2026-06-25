// Builds the interactive permission prompt and records the resulting session decision.

import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { matchingWildcard } from "./evaluator.ts";
import * as session from "./session.ts";
import type { CommandUnit, Config, PathAccess, Request } from "./types.ts";

/** Minimal UI surface this module needs (subset of ExtensionContext.ui). */
export interface PromptUi {
  select(title: string, options: string[]): Promise<string | undefined>;
  input(title: string, placeholder?: string): Promise<string | undefined>;
}

export interface PromptResult {
  block?: boolean;
  reason?: string;
}

interface Option {
  label: string;
  act(): PromptResult;
}

// The dialog text is built from model-controlled command/path strings. Strip
// control characters (newlines, ANSI escapes, etc.) and cap length so a crafted
// command cannot spoof or hide the real permission prompt.
function promptText(value: string): string {
  const cleaned = value
    .replace(/[\u0000-\u001F\u007F-\u009F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned.length > 500 ? `${cleaned.slice(0, 500)}…` : cleaned;
}

function describeRequest(req: Request): string {
  if (req.commandText !== undefined)
    return `bash: ${promptText(req.commandText)}`;
  if (req.accesses.length) {
    return `${req.tool}: ${req.accesses.map((a) => `${a.kind} ${promptText(a.path)}`).join(", ")}`;
  }
  return req.tool;
}

/** A "Accesses:" list of the files/directories a bash command touches, or "" if none. */
function accessBlock(req: Request): string {
  if (req.commandText === undefined || req.accesses.length === 0) return "";
  const seen = new Set<string>();
  const lines: string[] = [];
  for (const a of req.accesses) {
    const key = `${a.kind} ${a.path}`;
    if (seen.has(key)) continue;
    seen.add(key);
    if (lines.length < 12)
      lines.push(`  ${a.kind.padEnd(5)} ${promptText(a.path)}`);
  }
  if (lines.length === 0) return "";
  if (seen.size > lines.length)
    lines.push(`  … (${seen.size - lines.length} more)`);
  return `\nAccesses:\n${lines.join("\n")}`;
}

// Length-preserving control-char scrub (keeps offsets intact for highlighting) — same
// anti-spoofing intent as promptText, but without the whitespace collapse/truncate.
function scrub(value: string): string {
  return value.replace(/[\u0000-\u001F\u007F-\u009F]/g, " ");
}

// Bold + reverse video — a theme-agnostic highlight. The pi TUI renders ANSI and measures
// visible width correctly (select-list uses visibleWidth/truncateToWidth). Safe because the
// command text is scrubbed of all control chars first, so only these trusted codes remain.
const HL_START = "\x1b[1;7m";
const HL_END = "\x1b[0m";
const WIDTH_RESERVE = 4; // columns left for the dialog's own indent/border so it won't re-truncate

/** Current terminal width (columns), or 80 when unknown. Read via globalThis to avoid node typings. */
function terminalWidth(): number {
  const cols = (globalThis as { process?: { stdout?: { columns?: number } } })
    .process?.stdout?.columns;
  return typeof cols === "number" && cols > 0 ? cols : 80;
}

/** Keep the trailing portion of `s` fitting in `maxWidth` display columns, prefixing "…" if cut. */
function tailToWidth(s: string, maxWidth: number): string {
  if (maxWidth <= 0) return "";
  if (visibleWidth(s) <= maxWidth) return s;
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const graphemes = [...segmenter.segment(s)].map((g) => g.segment);
  let w = 0;
  let i = graphemes.length;
  while (i > 0) {
    const cw = visibleWidth(graphemes[i - 1]);
    if (w + cw > maxWidth - 1) break;
    w += cw;
    i--;
  }
  return `…${graphemes.slice(i).join("")}`;
}

/**
 * Render the command with the [s, e) segment color-highlighted, sized to the actual terminal
 * width: if the whole command fits on one row it is shown in full (no ellipsis); otherwise a
 * window centered on the highlighted command is shown, eliding only the side(s) actually cut.
 */
function renderHighlighted(command: string, range: [number, number]): string {
  const text = scrub(command);
  const s = Math.max(0, Math.min(range[0], text.length));
  const e = Math.max(s, Math.min(range[1], text.length));
  const mid = text.slice(s, e);
  const budget = Math.max(20, terminalWidth() - WIDTH_RESERVE);

  if (visibleWidth(text) <= budget)
    return `${text.slice(0, s)}${HL_START}${mid}${HL_END}${text.slice(e)}`;
  if (visibleWidth(mid) >= budget)
    return `${HL_START}${truncateToWidth(mid, budget, "…")}${HL_END}`;

  const beforeRaw = text.slice(0, s);
  const afterRaw = text.slice(e);
  let rem = budget - visibleWidth(mid);
  const beforeBudget = Math.min(visibleWidth(beforeRaw), Math.floor(rem * 0.3)); // keep a little lead context
  const before = tailToWidth(beforeRaw, beforeBudget);
  rem -= visibleWidth(before);
  const after = truncateToWidth(afterRaw, Math.max(0, rem), "…");
  return `${before}${HL_START}${mid}${HL_END}${after}`;
}

const OVERVIEW_MAX_LINES = 12; // commands listed before the rest is summarized as "… (N total)"
const OVERVIEW_LINE = 100; // max chars shown per command in the overview list

/** Numbered list of the commands in a multi-command bash line, for the overview prompt. */
function renderOverview(
  command: string,
  units: Array<CommandUnit & { range: [number, number] }>,
): string {
  const lines = units.map((u, i) => {
    const text = scrub(command.slice(u.range[0], u.range[1])).trim();
    const shown =
      text.length > OVERVIEW_LINE
        ? `${text.slice(0, OVERVIEW_LINE - 1)}…`
        : text;
    return `  ${String(i + 1).padStart(2)}  ${shown}`;
  });
  let body = lines.slice(0, OVERVIEW_MAX_LINES).join("\n");
  if (lines.length > OVERVIEW_MAX_LINES)
    body += `\n   … (${lines.length} total)`;
  return `Permission required — ${units.length} commands in this bash line:\n${body}`;
}

function denyMsg(req: Request): string {
  return `Permission denied by the user for ${describeRequest(req)}.`;
}

function recordSessionDeny(req: Request): void {
  if (req.commandText !== undefined) {
    session.add({
      decision: "deny",
      scope: "command",
      command: req.commandText,
    });
  } else if (req.accesses.length) {
    for (const a of req.accesses) {
      session.add({
        decision: "deny",
        scope: "path",
        pathKind: "file",
        base: session.pathBase(a.path, req.cwd, "file"),
        access: a.kind,
      });
    }
  } else {
    session.add({ decision: "deny", scope: "tool", tool: req.tool });
  }
}

const ASK_REASON = "__permission_checker_ask_reason__";
const REVIEW = "__permission_checker_review__";

function buildOptions(req: Request, config: Config): Option[] {
  const opts: Option[] = [];
  opts.push({ label: "Yes (allow once)", act: () => ({}) });

  if (req.accesses.length > 0) {
    const scopes: Array<["file" | "dir" | "gitroot", string]> = [
      ["file", "Yes, allow this file for the session"],
      ["dir", "Yes, allow this directory for the session"],
      ["gitroot", "Yes, allow this git repo for the session"],
    ];
    for (const [kind, label] of scopes) {
      opts.push({
        label,
        act: () => {
          for (const a of req.accesses) {
            session.add({
              decision: "allow",
              scope: "path",
              pathKind: kind,
              base: session.pathBase(a.path, req.cwd, kind),
              access: a.kind,
            });
          }
          return {};
        },
      });
    }
  } else if (req.commandText !== undefined) {
    const command = req.commandText;
    opts.push({
      label: "Yes, allow this command for the session",
      act: () => {
        session.add({ decision: "allow", scope: "command", command });
        return {};
      },
    });
    const wc = matchingWildcard(config, req);
    if (wc) {
      opts.push({
        label: `Yes, allow \`${wc.join(" ")}\` for the session`,
        act: () => {
          session.add({ decision: "allow", scope: "wildcard", tokens: wc });
          return {};
        },
      });
    }
  } else {
    opts.push({
      label: "Yes, allow this tool for the session",
      act: () => {
        session.add({ decision: "allow", scope: "tool", tool: req.tool });
        return {};
      },
    });
  }

  opts.push({
    label: "No (deny once)",
    act: () => ({ block: true, reason: denyMsg(req) }),
  });
  opts.push({
    label: "No, deny for the session",
    act: () => {
      recordSessionDeny(req);
      return { block: true, reason: denyMsg(req) };
    },
  });
  opts.push({
    label: "No, deny with reason",
    act: () => ({ block: true, reason: ASK_REASON }),
  });
  return opts;
}

/** Per-unit options for a single command in a multi-command bash prompt. */
function buildUnitOptions(unit: CommandUnit, req: Request): Option[] {
  return [
    {
      label: "Yes, allow this command for the session",
      act: () => {
        session.add({
          decision: "allow",
          scope: "wildcard",
          tokens: unit.argv,
        });
        return {};
      },
    },
    { label: "Yes (allow once)", act: () => ({}) },
    {
      label: "No (deny once)",
      act: () => ({ block: true, reason: denyMsg(req) }),
    },
    {
      label: "No, deny for the session",
      act: () => {
        session.add({ decision: "deny", scope: "wildcard", tokens: unit.argv });
        return { block: true, reason: denyMsg(req) };
      },
    },
    {
      label: "No, deny with reason",
      act: () => ({ block: true, reason: ASK_REASON }),
    },
  ];
}

/** Per-path options for a single file/directory access in the review flow. */
function buildAccessOptions(a: PathAccess, req: Request): Option[] {
  const scopes: Array<["file" | "dir" | "gitroot", string]> = [
    ["file", "Yes, allow this file for the session"],
    ["dir", "Yes, allow this directory for the session"],
    ["gitroot", "Yes, allow this git repo for the session"],
  ];
  const opts: Option[] = scopes.map(([kind, label]) => ({
    label,
    act: () => {
      session.add({
        decision: "allow",
        scope: "path",
        pathKind: kind,
        base: session.pathBase(a.path, req.cwd, kind),
        access: a.kind,
      });
      return {};
    },
  }));
  opts.push({ label: "Yes (allow once)", act: () => ({}) });
  opts.push({
    label: "No (deny once)",
    act: () => ({ block: true, reason: denyMsg(req) }),
  });
  opts.push({
    label: "No, deny for the session",
    act: () => {
      session.add({
        decision: "deny",
        scope: "path",
        pathKind: "file",
        base: session.pathBase(a.path, req.cwd, "file"),
        access: a.kind,
      });
      return { block: true, reason: denyMsg(req) };
    },
  });
  opts.push({
    label: "No, deny with reason",
    act: () => ({ block: true, reason: ASK_REASON }),
  });
  return opts;
}

/** Show one select dialog, run the chosen action, and resolve the optional deny-reason input. */
async function presentOptions(
  ui: PromptUi,
  title: string,
  opts: Option[],
  req: Request,
): Promise<PromptResult> {
  const picked = await ui.select(
    title,
    opts.map((o) => o.label),
  );
  if (picked === undefined) return { block: true, reason: denyMsg(req) };
  const chosen = opts.find((o) => o.label === picked);
  if (!chosen) return { block: true, reason: denyMsg(req) };
  const result = chosen.act();
  if (result.reason === ASK_REASON) {
    const reason = await ui.input(
      "Reason for denying (optional)",
      "Shown back to the agent",
    );
    return {
      block: true,
      reason: reason && reason.trim() ? reason.trim() : denyMsg(req),
    };
  }
  return result;
}

/** AI explanation block shown atop the prompt; sanitized line-by-line to preserve bullets. */
function explainBlock(explanation?: string): string {
  if (!explanation || !explanation.trim()) return "";
  const lines = explanation
    .split("\n")
    .map((l) => scrub(l).trim())
    .filter((l) => l.length > 0)
    .slice(0, 8)
    .map((l) => (l.length > 200 ? `${l.slice(0, 199)}…` : l));
  if (lines.length === 0) return "";
  return `What this script does (AI):\n${lines.join("\n")}\n──\n`;
}

/** Prompt the user for an ask decision and return the block/allow result. Fails closed on UI errors. */
export async function askUser(
  ui: PromptUi,
  req: Request,
  config: Config,
  explanation?: string,
): Promise<PromptResult> {
  try {
    const intro = explainBlock(explanation);
    // For a multi-command bash line (pipeline / `&&` / `;`), show an overview of all commands
    // first with a bulk allow/deny, and only drop into per-command prompts if asked. Any deny
    // blocks the whole line (partial execution isn't possible); all commands must be allowed.
    const ranged = req.units
      .filter(
        (u): u is CommandUnit & { range: [number, number] } =>
          u.range !== undefined,
      )
      .sort((a, b) => a.range[0] - b.range[0]);
    if (req.commandText !== undefined && ranged.length >= 2) {
      const command = req.commandText;
      const overview: Option[] = [
        {
          label: "Review & decide one by one",
          act: () => ({ reason: REVIEW }),
        },
        {
          label: "Allow all for the session",
          act: () => {
            for (const u of ranged)
              session.add({
                decision: "allow",
                scope: "wildcard",
                tokens: u.argv,
              });
            return {};
          },
        },
        { label: "Allow all (once)", act: () => ({}) },
        {
          label: "Deny all",
          act: () => ({ block: true, reason: denyMsg(req) }),
        },
        {
          label: "Deny with reason",
          act: () => ({ block: true, reason: ASK_REASON }),
        },
      ];
      const top = await presentOptions(
        ui,
        `${intro}${renderOverview(command, ranged)}${accessBlock(req)}`,
        overview,
        req,
      );
      if (top.reason !== REVIEW) return top; // Allow all / Deny all / cancel

      // 1) Decide each accessed file/directory first. Approving a broader scope (a directory or
      //    git repo) covers paths nested under it, so those are skipped on later iterations.
      const seen = new Set<string>();
      const paths = req.accesses.filter((a) => {
        const k = `${a.kind} ${a.path}`;
        return seen.has(k) ? false : (seen.add(k), true);
      });
      for (let k = 0; k < paths.length; k++) {
        const a = paths[k];
        // Re-check each time: an earlier "allow directory/git repo" may now cover this path.
        if (
          session.matchesAllow({
            ...req,
            commandText: undefined,
            units: [],
            accesses: [a],
          })
        )
          continue;
        const title = `Permission required — path ${k + 1}/${paths.length}\n${a.kind.padEnd(5)} ${promptText(a.path)}`;
        const res = await presentOptions(
          ui,
          title,
          buildAccessOptions(a, req),
          req,
        );
        if (res.block) return res; // a deny on any path short-circuits the whole line
      }

      // 2) Then decide each command.
      for (let k = 0; k < ranged.length; k++) {
        const unit = ranged[k];
        if (
          session.matchesAllow({
            ...req,
            commandText: undefined,
            units: [unit],
            accesses: [],
          })
        )
          continue;
        const title = `Permission required — command ${k + 1}/${ranged.length}\n${renderHighlighted(command, unit.range)}`;
        const res = await presentOptions(
          ui,
          title,
          buildUnitOptions(unit, req),
          req,
        );
        if (res.block) return res; // a deny on any command short-circuits the whole line
      }
      return {}; // every path and command allowed
    }

    return await presentOptions(
      ui,
      `${intro}Permission required\n${describeRequest(req)}${accessBlock(req)}`,
      buildOptions(req, config),
      req,
    );
  } catch {
    return {
      block: true,
      reason: `Permission prompt failed; denying. ${denyMsg(req)}`,
    };
  }
}
