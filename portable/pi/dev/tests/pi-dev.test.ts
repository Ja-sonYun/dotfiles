import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import type { TestContext } from "node:test";

const sourceScript = fileURLToPath(new URL("../pi-dev", import.meta.url));

function fixture(t: TestContext) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi dev test-")));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const home = join(root, "home");
  const agentDir = join(home, ".pi/agent-dev");
  const config = join(home, ".pi/agent/extensions/providers/providers.json");
  const cwd = join(root, "project");
  const bin = join(root, "bin");

  for (const directory of [home, cwd, bin]) {
    mkdirSync(directory, { recursive: true });
  }
  writeFileSync(
    join(bin, "pi"),
    `#!${process.execPath}
process.stdout.write(JSON.stringify({
  args: process.argv.slice(2),
  cwd: process.cwd(),
  config: process.env.PI_PROVIDERS_CONFIG,
  agentDir: process.env.PI_CODING_AGENT_DIR,
  marker: process.env.PI_TEST_MARKER,
}));
process.exit(Number(process.env.PI_TEST_EXIT ?? 0));
`,
    { mode: 0o755 },
  );

  return {
    agentDir,
    config,
    cwd,
    run(args: string[] = [], env: NodeJS.ProcessEnv = {}) {
      return spawnSync("/bin/bash", [sourceScript, ...args], {
        cwd,
        env: {
          PATH: `${bin}:/usr/bin:/bin`,
          HOME: home,
          PI_TEST_MARKER: "inherited-value",
          ...env,
        },
        encoding: "utf8",
      });
    },
  };
}

test("selects the development profile and leaves resource discovery to Pi", (t) => {
  const local = fixture(t);
  const args = [
    "-e",
    "./extension with spaces.ts",
    "--model",
    "test/model",
    "quoted ' $text",
  ];
  const result = local.run(args);
  assert.equal(result.status, 0, result.stderr);
  const captured: unknown = JSON.parse(result.stdout);
  assert.ok(typeof captured === "object" && captured !== null);
  assert.ok(
    "cwd" in captured &&
      "agentDir" in captured &&
      "marker" in captured &&
      "args" in captured,
  );

  assert.equal(captured.cwd, local.cwd);
  assert.equal(captured.agentDir, local.agentDir);
  assert.equal("config" in captured, false);
  assert.equal(captured.marker, "inherited-value");
  assert.deepEqual(captured.args, args);
});

test("preserves an explicit provider configuration and propagates Pi's exit status", (t) => {
  const local = fixture(t);
  const override = join(local.cwd, "custom providers.json");
  const result = local.run([], {
    PI_PROVIDERS_CONFIG: override,
    PI_TEST_EXIT: "23",
  });

  assert.equal(result.status, 23, result.stderr);
  const captured: unknown = JSON.parse(result.stdout);
  assert.ok(typeof captured === "object" && captured !== null);
  assert.ok(
    "cwd" in captured &&
      "agentDir" in captured &&
      "marker" in captured &&
      "args" in captured,
  );
  assert.ok("config" in captured);
  assert.equal(captured.config, override);
  assert.equal(captured.agentDir, local.agentDir);
  assert.deepEqual(captured.args, []);
});

test("does not inherit another profile's settings or provider configuration path", (t) => {
  const local = fixture(t);
  const result = local.run([], {
    PI_CODING_AGENT_DIR: join(local.cwd, "another agent"),
  });

  assert.equal(result.status, 0, result.stderr);
  const captured: unknown = JSON.parse(result.stdout);
  assert.ok(typeof captured === "object" && captured !== null);
  assert.ok(
    "cwd" in captured &&
      "agentDir" in captured &&
      "marker" in captured &&
      "args" in captured,
  );
  assert.equal(captured.agentDir, local.agentDir);
  assert.equal("config" in captured, false);
});
