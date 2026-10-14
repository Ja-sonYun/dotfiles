import { createHash } from "node:crypto";
import type { Actor, Assessment, Call } from "./policy.ts";

export interface RuleResult {
  fingerprint: string;
  results: {
    id: string;
    verdict: "compliant" | "violation" | "unclear";
    message?: string;
  }[];
  errors: string[];
  needs_summary?: boolean | null;
}
export interface Approval {
  call: Call;
  actor: Actor;
  request: string;
  reasons: string[];
  sessionAllowed: boolean;
  summary?: string;
}
export type Outcome = { block: true; reason: string } | undefined;
export type Approve = (
  approval: Approval,
  signal: AbortSignal,
) => Promise<"once" | "session" | "deny">;

export function fingerprint(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

export class PermissionSession {
  private grants = new Map<string, string>();
  private generation = 0;
  private queue: Promise<unknown> = Promise.resolve();
  private controller = new AbortController();

  reset(): void {
    this.grants.clear();
    this.generation++;
    this.controller.abort();
    this.controller = new AbortController();
  }

  async check(
    call: Call,
    actor: Actor,
    request: string,
    policyVersion: string,
    assessment: Assessment,
    evaluate: (signal: AbortSignal) => Promise<RuleResult>,
    approve: Approve,
    signal?: AbortSignal,
    prepare?: (rules: RuleResult, signal: AbortSignal) => Promise<void>,
  ): Promise<Outcome> {
    const generation = this.generation;
    const cancellation = AbortSignal.any([
      this.controller.signal,
      ...(signal ? [signal] : []),
    ]);
    if (cancellation.aborted)
      return { block: true, reason: "Permission check cancelled" };
    if (assessment.decision === "deny")
      return { block: true, reason: assessment.reasons.join("\n") };
    const reasons = [...assessment.reasons];
    let rules: RuleResult;
    try {
      rules = await evaluate(cancellation);
      if (
        !rules.fingerprint ||
        !Array.isArray(rules.errors) ||
        !Array.isArray(rules.results) ||
        rules.results.some(
          (rule) =>
            !["compliant", "violation", "unclear"].includes(rule.verdict),
        )
      ) {
        throw new Error("Invalid rule evaluation");
      }
      if (
        !rules.results.some((rule) => rule.id === "permission_request_scope")
      ) {
        rules.errors.push("Request scope was not checked");
      }
    } catch {
      rules = {
        fingerprint: "unavailable",
        results: [],
        errors: [
          "Rule evaluation unavailable; inspect the complete call manually",
        ],
      };
    }
    if (cancellation.aborted || generation !== this.generation)
      return { block: true, reason: "Permission context changed" };
    const violations = rules.results.filter(
      (rule) => rule.verdict === "violation",
    );
    if (violations.length)
      return {
        block: true,
        reason: violations
          .map((rule) => `${rule.id}: ${rule.message ?? "Rule violation"}`)
          .join("\n"),
      };
    try {
      await prepare?.(rules, cancellation);
    } catch {
      return {
        block: true,
        reason:
          "Tool explanation could not be prepared; the call was not executed",
      };
    }
    if (cancellation.aborted || generation !== this.generation)
      return { block: true, reason: "Permission context changed" };
    const uncertain =
      rules.errors.length > 0 ||
      rules.results.some((rule) => rule.verdict === "unclear");
    reasons.push(
      ...rules.errors,
      ...rules.results
        .filter((rule) => rule.verdict !== "compliant")
        .map((rule) => `${rule.id}: ${rule.verdict}`),
    );
    if (assessment.decision === "allow" && !uncertain) return undefined;
    const key = fingerprint([
      policyVersion,
      call.toolName,
      call.input,
      actor,
      request,
      assessment.reasons,
    ]);
    if (this.grants.get(key) !== rules.fingerprint) this.grants.delete(key);
    if (!uncertain && this.grants.get(key) === rules.fingerprint)
      return undefined;

    const pending = this.queue.then(async (): Promise<Outcome> => {
      if (cancellation.aborted || generation !== this.generation)
        return { block: true, reason: "Permission context changed" };
      if (!uncertain && this.grants.get(key) === rules.fingerprint)
        return undefined;
      let choice: "once" | "session" | "deny" = "deny";
      try {
        choice = await approve(
          { call, actor, request, reasons, sessionAllowed: !uncertain },
          cancellation,
        );
      } catch {
        return { block: true, reason: "Approval unavailable" };
      }
      if (cancellation.aborted || generation !== this.generation)
        return { block: true, reason: "Approval cancelled" };
      if (choice === "deny")
        return { block: true, reason: "User approval required or declined" };
      if (choice === "session" && !uncertain)
        this.grants.set(key, rules.fingerprint);
      return undefined;
    });
    this.queue = pending.catch(() => {});
    return pending;
  }
}
