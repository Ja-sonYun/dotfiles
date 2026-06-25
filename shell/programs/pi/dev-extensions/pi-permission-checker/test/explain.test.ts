import assert from "node:assert/strict";
import { test } from "node:test";
import { parserAvailable } from "../src/bash-ast.ts";
import { analyzeBashCommand } from "../src/commands/index.ts";
import {
  type CompleteFn,
  explainScripts,
  type ExplainCtx,
} from "../src/explain.ts";

const available = await parserAvailable();
const needsParser = available
  ? {}
  : { skip: "tree-sitter parser unavailable (run `npm install`)" };

/** A ctx with a working model auth (mirrors the real ModelRegistry surface we use). */
function okCtx(over: Partial<ExplainCtx> = {}): ExplainCtx {
  return {
    cwd: "/repo",
    model: {},
    modelRegistry: {
      getApiKeyAndHeaders: async () => ({ ok: true, apiKey: "k", headers: {} }),
    },
    ...over,
  };
}

/** Injectable completion adapter that records the prompt and returns a fixed reply. */
function fakeComplete(
  captured: { text?: string },
  reply = "• does X",
): CompleteFn {
  return async (_model, context) => {
    captured.text = (
      context as { messages: Array<{ content: Array<{ text: string }> }> }
    ).messages[0].content[0].text;
    return { stopReason: "end", content: [{ type: "text", text: reply }] };
  };
}

test("explainScripts returns the model's explanation and sends the code", async () => {
  const captured: { text?: string } = {};
  const out = await explainScripts(
    [{ lang: "python", code: "print('hi')" }],
    okCtx(),
    [],
    fakeComplete(captured, "• prints hello"),
  );
  assert.equal(out, "• prints hello");
  assert.match(captured.text ?? "", /print\('hi'\)/);
  assert.match(captured.text ?? "", /lang="python"/);
});

test("explainScripts returns undefined with no model or no auth method", async () => {
  const complete = fakeComplete({});
  assert.equal(
    await explainScripts(
      [{ lang: "python", code: "x" }],
      okCtx({ model: undefined }),
      [],
      complete,
    ),
    undefined,
  );
  assert.equal(
    await explainScripts(
      [{ lang: "python", code: "x" }],
      { cwd: "/repo", model: {}, modelRegistry: {} },
      [],
      complete,
    ),
    undefined,
  );
});

test("explainScripts returns undefined when auth is not ok", async () => {
  const ctx = okCtx({
    modelRegistry: {
      getApiKeyAndHeaders: async () => ({ ok: false, error: "no key" }),
    },
  });
  assert.equal(
    await explainScripts(
      [{ lang: "python", code: "x" }],
      ctx,
      [],
      fakeComplete({}),
    ),
    undefined,
  );
});

test("explainScripts returns undefined when the model call throws", async () => {
  const complete: CompleteFn = async () => {
    throw new Error("boom");
  };
  assert.equal(
    await explainScripts(
      [{ lang: "python", code: "x" }],
      okCtx(),
      [],
      complete,
    ),
    undefined,
  );
});

test("explainScripts skips a deny-listed file's contents (no targets left -> undefined)", async () => {
  const captured: { text?: string } = {};
  // The only target is a denied path; its contents must not be read/sent, leaving nothing to explain.
  const out = await explainScripts(
    [{ lang: "python", path: "secrets/.env.py" }],
    okCtx(),
    ["**/.env*"],
    fakeComplete(captured),
  );
  assert.equal(out, undefined);
  assert.equal(captured.text, undefined); // completion never called
});

test(
  "collects inline interpreter code as an explain target",
  needsParser,
  async () => {
    const a = await analyzeBashCommand(
      "python -c 'import os; os.remove(\"x\")'",
      "/repo",
    );
    assert.ok(
      a.explainTargets.some(
        (t) => t.lang === "python" && /os\.remove/.test(t.code ?? ""),
      ),
    );
  },
);

test(
  "collects node -e and eval/sh -c scripts and script files",
  needsParser,
  async () => {
    const node = await analyzeBashCommand(
      "node -e 'fetch(\"http://x\")'",
      "/repo",
    );
    assert.ok(
      node.explainTargets.some(
        (t) => t.lang === "js" && /fetch/.test(t.code ?? ""),
      ),
    );

    const ev = await analyzeBashCommand("eval 'rm -rf build'", "/repo");
    assert.ok(
      ev.explainTargets.some(
        (t) => t.lang === "shell" && /rm -rf build/.test(t.code ?? ""),
      ),
    );

    const file = await analyzeBashCommand("python script.py", "/repo");
    assert.ok(
      file.explainTargets.some(
        (t) => t.lang === "python" && t.path === "script.py",
      ),
    );

    const plain = await analyzeBashCommand("cat notes.txt", "/repo");
    assert.equal(plain.explainTargets.length, 0); // non-interpreter command: nothing to explain
  },
);
