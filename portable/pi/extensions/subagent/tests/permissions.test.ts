import assert from "node:assert/strict";
import { once } from "node:events";
import { ChildProcess } from "node:child_process";
import test from "node:test";
import { connectPermissions } from "../permissions.ts";

class PermissionChild extends ChildProcess {
  override connected = true;

  override send(message: unknown, ...args: unknown[]): boolean {
    this.emit("reply", JSON.parse(JSON.stringify(message)));
    const callback = args.at(-1);
    if (typeof callback === "function") callback(null);
    return true;
  }
}

test("child requests use the parent's bound checker and return only its decision", async () => {
  const proc = new PermissionChild();
  let calls = 0;
  connectPermissions(proc, {
    extension: "fixture.ts",
    mode: "default",
    rules: async () => ({}),
    check: async (call) => {
      calls++;
      assert.equal(call.toolName, "write");
      return { block: true, reason: "readonly" };
    },
  });
  const reply = once(proc, "reply");
  proc.emit("message", {
    type: "pi:permission:check",
    id: "one",
    actor: "forged-main",
    mode: "default",
    call: { toolName: "write", input: {} },
  });
  assert.deepEqual((await reply)[0], {
    type: "pi:permission:result",
    id: "one",
    allow: false,
    reason: "readonly",
  });
  assert.equal(calls, 1);
});

test("parent checker errors deny execution", async () => {
  const proc = new PermissionChild();
  connectPermissions(proc, {
    extension: "fixture.ts",
    mode: "default",
    rules: async () => ({}),
    check: async () => {
      throw new Error("unavailable");
    },
  });
  const reply = once(proc, "reply");
  proc.emit("message", {
    type: "pi:permission:check",
    id: "one",
    call: { toolName: "read", input: {} },
  });
  const response: unknown = (await reply)[0];
  assert.ok(
    typeof response === "object" && response !== null && "allow" in response,
  );
  assert.equal(response.allow, false);
});

test("disconnect aborts a pending parent approval without replying to a dead child", async () => {
  const proc = new PermissionChild();
  let checked: (() => void) | undefined;
  const ready = new Promise<void>((resolve) => {
    checked = resolve;
  });
  let approvalSignal: AbortSignal | undefined;
  connectPermissions(proc, {
    extension: "fixture.ts",
    mode: "default",
    rules: async () => ({}),
    check: async (_call, signal) => {
      approvalSignal = signal;
      assert.ok(checked);
      checked();
      await new Promise<void>((resolve) =>
        signal.addEventListener("abort", () => resolve(), { once: true }),
      );
    },
  });
  proc.on("reply", () => assert.fail("must not reply after cancellation"));
  proc.emit("message", {
    type: "pi:permission:check",
    id: "one",
    call: { toolName: "read", input: {} },
  });
  await ready;
  proc.connected = false;
  proc.emit("disconnect");
  assert.ok(approvalSignal);
  assert.equal(approvalSignal.aborted, true);
});
