import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import test from "node:test";
import { connectPermissions } from "../permissions.ts";

function child() {
  const proc = new EventEmitter();
  proc.connected = true;
  proc.send = (message, callback) => {
    proc.emit("reply", message);
    callback();
  };
  return proc;
}

test("child requests use the parent's bound checker and return only its decision", async () => {
  const proc = child();
  let calls = 0;
  connectPermissions(proc, {
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
  const proc = child();
  connectPermissions(proc, {
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
  assert.equal((await reply)[0].allow, false);
});

test("disconnect aborts a pending parent approval without replying to a dead child", async () => {
  const proc = child();
  let checked;
  const ready = new Promise((resolve) => {
    checked = resolve;
  });
  let approvalSignal;
  connectPermissions(proc, {
    check: async (_call, signal) => {
      approvalSignal = signal;
      checked();
      await new Promise((resolve) =>
        signal.addEventListener("abort", resolve, { once: true }),
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
  assert.equal(approvalSignal.aborted, true);
});
