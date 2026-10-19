import { createHash, randomUUID } from "node:crypto";
import type { Actor, Assessment, Call } from "./policy.ts";

export interface RuleResult {
  fingerprint: string;
  file_state?: string;
  status?: string;
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
type Snapshot = (signal: AbortSignal) => Promise<RuleResult>;
interface RuleRequest {
  key: string;
  owner: string;
  approval: Approval;
  rules: RuleResult;
  snapshot: Snapshot;
  approved: boolean;
}

export function fingerprint(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

export class PermissionSession {
  private grants = new Map<string, string>();
  private ruleRequests = new Map<string, RuleRequest>();
  private generation = 0;
  private queue: Promise<unknown> = Promise.resolve();
  private controller = new AbortController();

  reset(): void {
    this.grants.clear();
    this.ruleRequests.clear();
    this.generation++;
    this.controller.abort();
    this.controller = new AbortController();
  }

  private ruleKey(
    call: Call,
    actor: Actor,
    request: string,
    policyVersion: string,
    rules: RuleResult,
  ): string {
    return fingerprint([
      call.toolName,
      call.input,
      actor,
      request,
      policyVersion,
      rules.fingerprint,
      rules.file_state,
    ]);
  }

  private recordRules(
    call: Call,
    actor: Actor,
    request: string,
    policyVersion: string,
    rules: RuleResult,
    reasons: string[],
    snapshot: Snapshot,
  ): string | undefined {
    if (!rules.file_state || rules.fingerprint === "unavailable")
      return undefined;
    const key = this.ruleKey(call, actor, request, policyVersion, rules);
    for (const [id, pending] of this.ruleRequests) {
      if (pending.key === key) return id;
    }
    const id = randomUUID();
    this.ruleRequests.set(id, {
      key,
      owner: fingerprint([actor, request, policyVersion]),
      approval: structuredClone({
        call,
        actor,
        request,
        reasons,
        sessionAllowed: false,
      }),
      rules: structuredClone(rules),
      snapshot,
      approved: false,
    });
    return id;
  }

  private async consumeRules(
    call: Call,
    actor: Actor,
    request: string,
    policyVersion: string,
    rules: RuleResult,
    signal: AbortSignal,
  ): Promise<boolean> {
    const key = this.ruleKey(call, actor, request, policyVersion, rules);
    for (const [id, pending] of this.ruleRequests) {
      if (!pending.approved || pending.key !== key) continue;
      const state = await pending.snapshot(signal);
      if (signal.aborted || this.ruleRequests.get(id) !== pending) return false;
      this.ruleRequests.delete(id);
      return (
        state.fingerprint === rules.fingerprint &&
        state.file_state === rules.file_state
      );
    }
    return false;
  }

  async requestRuleApproval(
    id: string,
    actor: Actor,
    request: string,
    policyVersion: string,
    approve: Approve,
    signal?: AbortSignal,
  ): Promise<Record<string, unknown>> {
    const pending = this.ruleRequests.get(id);
    const cancellation = AbortSignal.any([
      this.controller.signal,
      ...(signal ? [signal] : []),
    ]);
    if (
      !pending ||
      pending.approved ||
      pending.owner !== fingerprint([actor, request, policyVersion])
    ) {
      return {
        status: "unavailable",
        reason: "Unknown or expired request ID for this actor",
      };
    }
    const valid = async () => {
      const state = await pending.snapshot(cancellation);
      return (
        !cancellation.aborted &&
        this.ruleRequests.get(id) === pending &&
        !pending.approved &&
        state.fingerprint === pending.rules.fingerprint &&
        state.file_state === pending.rules.file_state
      );
    };
    try {
      if (!(await valid()))
        return { status: "unavailable", reason: "Request state changed" };
      const choice = await approve(pending.approval, cancellation);
      if (choice !== "once") return { status: "not_approved", request_id: id };
      if (!(await valid()))
        return { status: "unavailable", reason: "Request state changed" };
      pending.approved = true;
      return { status: "approved", request_id: id };
    } catch {
      return {
        status: "unavailable",
        reason: "Approval cancelled or state unavailable",
      };
    }
  }

  async checkTask(
    call: Call,
    actor: Actor,
    request: string,
    policyVersion: string,
    rules: RuleResult,
    snapshot: Snapshot,
    signal: AbortSignal,
  ): Promise<Record<string, unknown>> {
    const cancellation = AbortSignal.any([this.controller.signal, signal]);
    if (cancellation.aborted)
      return { status: "incomplete", errors: ["Context changed"] };
    if (
      await this.consumeRules(
        call,
        actor,
        request,
        policyVersion,
        rules,
        cancellation,
      )
    ) {
      return {
        status: "user_approved",
        message:
          "An exception was approved once for this exact text; this is not execution permission.",
      };
    }
    if (cancellation.aborted)
      return { status: "incomplete", errors: ["Context changed"] };
    const findings = rules.results.filter(
      (rule) => rule.verdict !== "compliant",
    );
    const response: Record<string, unknown> = {
      ...rules,
      status: rules.status ?? "incomplete",
    };
    if (findings.length || rules.errors.length) {
      response.request_id = this.recordRules(
        call,
        actor,
        request,
        policyVersion,
        rules,
        [
          ...rules.errors,
          ...findings.map(
            (rule) =>
              `${rule.id}: ${rule.verdict}${rule.message ? `: ${rule.message}` : ""}`,
          ),
        ],
        snapshot,
      );
      if (response.request_id)
        response.approval_tool = "rules_request_approval";
    }
    return response;
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
    snapshot?: Snapshot,
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
    const overridden = await this.consumeRules(
      call,
      actor,
      request,
      policyVersion,
      rules,
      cancellation,
    );
    if (cancellation.aborted || generation !== this.generation)
      return { block: true, reason: "Permission context changed" };
    if (overridden) return undefined;
    if (violations.length && !overridden) {
      const findings = violations.map(
        (rule) => `${rule.id}: ${rule.message ?? "Rule violation"}`,
      );
      const id = snapshot
        ? this.recordRules(
            call,
            actor,
            request,
            policyVersion,
            rules,
            [...reasons, ...rules.errors, ...findings],
            snapshot,
          )
        : undefined;
      return {
        block: true,
        reason: [
          ...findings,
          id
            ? `Request ID: ${id}. Call rules_request_approval with request_id to ask the user for a one-time exception.`
            : "Approval ID unavailable: request state could not be captured.",
        ].join("\n"),
      };
    }
    // Standing project-read authorization covers only request-scope uncertainty.
    const unclearRules = rules.results.filter(
      (rule) =>
        rule.verdict === "unclear" &&
        !(
          assessment.decision === "allow" &&
          assessment.projectRead &&
          rule.id === "permission_request_scope"
        ),
    );
    const uncertain = rules.errors.length > 0 || unclearRules.length > 0;
    reasons.push(
      ...rules.errors,
      ...unclearRules.map((rule) =>
        rule.id === "permission_request_scope"
          ? "ask: Cannot confirm this call matches your request (permission_request_scope: unclear)"
          : `ask: Cannot verify rule ${rule.id} (${rule.verdict})${rule.message ? `: ${rule.message}` : ""}`,
      ),
    );
    if (uncertain && snapshot) {
      const id = this.recordRules(
        call,
        actor,
        request,
        policyVersion,
        rules,
        reasons,
        snapshot,
      );
      return {
        block: true,
        reason: [
          ...reasons,
          id
            ? `Request ID: ${id}. Call rules_request_approval with request_id to ask the user for a one-time exception.`
            : "Approval ID unavailable: request state could not be captured.",
        ].join("\n"),
      };
    }
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
