// Asks the current pi model, in a separate one-shot context, to explain what the scripts a
// bash command would run actually do. The explanation is advisory only — it is shown in the
// permission prompt and never changes the allow/deny decision. Any failure yields undefined
// (the prompt simply shows no explanation), so this can never block or weaken enforcement.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { matchPathGlob, resolvePath } from "./paths.ts";
import type { ExplainTarget } from "./types.ts";

/** Minimal slice of ExtensionContext this module needs (kept structural for testing). */
export interface ExplainCtx {
  model?: unknown;
  modelRegistry?: {
    // Returns { ok: true, apiKey?, headers? } | { ok: false, error }.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    getApiKeyAndHeaders?: (model: any) => Promise<any>;
  };
  signal?: AbortSignal;
  cwd: string;
}

/** One-shot completion adapter (pi-ai `completeSimple` shape). Injectable for tests. */
export type CompleteFn = (
  model: unknown,
  context: unknown,
  options: unknown,
) => Promise<{
  stopReason?: string;
  errorMessage?: string;
  content?: Array<{ type: string; text?: string }>;
}>;

const MAX_PER_SCRIPT = 4000; // chars per snippet sent to the model
const MAX_TOTAL = 12000; // chars across all snippets
const TIMEOUT_MS = 15000;

const SYSTEM_PROMPT =
  "You are a security reviewer for an AI coding agent. The agent is about to EXECUTE the " +
  "script(s) below. Explain concisely what they do — 2 to 4 short bullet points — and call out " +
  "any file writes/deletions, network access, credential use, or otherwise destructive or " +
  "side-effecting behavior. Report only what the code does; do not run anything or give advice.";

// Resolve pi-ai's standalone completeSimple. The package is nested under pi-coding-agent's own
// node_modules (not our extension's), so resolve it relative to pi-coding-agent. Memoized;
// returns undefined if unavailable (then no explanation is shown).
let completeSimplePromise: Promise<CompleteFn | undefined> | undefined;
function loadCompleteSimple(): Promise<CompleteFn | undefined> {
  if (completeSimplePromise) return completeSimplePromise;
  completeSimplePromise = (async () => {
    try {
      const req = createRequire(import.meta.url);
      let entry: string;
      try {
        const pca = req.resolve("@earendil-works/pi-coding-agent");
        entry = createRequire(pca).resolve("@earendil-works/pi-ai");
      } catch {
        entry = req.resolve("@earendil-works/pi-ai"); // hoisted layout fallback
      }
      const mod = (await import(pathToFileURL(entry).href)) as {
        completeSimple?: CompleteFn;
      };
      return typeof mod.completeSimple === "function"
        ? mod.completeSimple
        : undefined;
    } catch {
      return undefined;
    }
  })();
  return completeSimplePromise;
}

/** Read a script file's contents, skipping deny-listed paths and capping size. */
function readScript(
  target: ExplainTarget,
  cwd: string,
  denyPathGlobs: string[],
): string | undefined {
  if (!target.path) return undefined;
  // Never ship the contents of a denied path (e.g. .env, .ssh) to the model.
  if (denyPathGlobs.some((g) => matchPathGlob(g, target.path!, cwd)))
    return undefined;
  try {
    return readFileSync(resolvePath(target.path, cwd), "utf-8").slice(
      0,
      MAX_PER_SCRIPT,
    );
  } catch {
    return undefined;
  }
}

/** Build the `<script>`-wrapped prompt body, or undefined if nothing analyzable remains. */
function buildPrompt(
  targets: ExplainTarget[],
  cwd: string,
  denyPathGlobs: string[],
): string | undefined {
  const blocks: string[] = [];
  let total = 0;
  for (const t of targets) {
    const body =
      t.code !== undefined
        ? t.code.slice(0, MAX_PER_SCRIPT)
        : readScript(t, cwd, denyPathGlobs);
    if (body === undefined || body.trim() === "") continue;
    if (total + body.length > MAX_TOTAL) break;
    total += body.length;
    const label = t.path ? ` path="${t.path}"` : "";
    blocks.push(`<script lang="${t.lang}"${label}>\n${body}\n</script>`);
  }
  if (blocks.length === 0) return undefined;
  return `${blocks.join("\n\n")}\n\nExplain what the above will do when executed.`;
}

/**
 * Ask the current model to explain the command's scripts. Returns a short explanation, or
 * undefined when there is nothing to explain / no model / the call fails or times out.
 * `complete` is injectable for tests; in production it resolves pi-ai's completeSimple.
 */
export async function explainScripts(
  targets: ExplainTarget[] | undefined,
  ctx: ExplainCtx,
  denyPathGlobs: string[],
  complete?: CompleteFn,
): Promise<string | undefined> {
  if (!targets || targets.length === 0) return undefined;
  if (!ctx.model || !ctx.modelRegistry?.getApiKeyAndHeaders) return undefined;

  const promptText = buildPrompt(targets, ctx.cwd, denyPathGlobs);
  if (!promptText) return undefined;

  const completeFn = complete ?? (await loadCompleteSimple());
  if (!completeFn) return undefined;

  try {
    const auth = await ctx.modelRegistry.getApiKeyAndHeaders(ctx.model);
    if (!auth || auth.ok === false) return undefined;

    const context = {
      systemPrompt: SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content: [{ type: "text", text: promptText }],
          timestamp: Date.now(),
        },
      ],
    };
    const options = {
      maxTokens: 400,
      signal: ctx.signal,
      apiKey: auth.apiKey,
      headers: auth.headers,
    };

    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new Error("explain timeout")),
        TIMEOUT_MS,
      );
    });
    let res;
    try {
      res = await Promise.race([
        completeFn(ctx.model, context, options),
        timeout,
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }

    if (res.stopReason === "error") return undefined;
    const text = (res.content ?? [])
      .filter((c) => c.type === "text")
      .map((c) => c.text ?? "")
      .join("")
      .trim();
    return text || undefined;
  } catch {
    return undefined;
  }
}
