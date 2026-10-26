import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { TestContext } from "node:test";
import type { Provider } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ProviderConfig,
} from "@earendil-works/pi-coding-agent";

type SecretValue = string | { _secret: string };
type RegisteredProvider = {
  id: string;
  definition: ProviderConfig & {
    models: NonNullable<ProviderConfig["models"]>;
    refreshModels: NonNullable<ProviderConfig["refreshModels"]>;
  };
};

function refreshContext(
  signal: AbortSignal = new AbortController().signal,
): Parameters<NonNullable<ProviderConfig["refreshModels"]>>[0] {
  return {
    signal,
    allowNetwork: true,
    publish: async () => assert.fail("Unexpected model publication"),
  };
}

async function loadProvider(
  t: TestContext,
  {
    baseUrl = "https://provider.invalid",
    apiKey = "test-key",
    secretFiles = false,
  }: {
    baseUrl?: SecretValue;
    apiKey?: SecretValue;
    secretFiles?: boolean;
  } = {},
): Promise<RegisteredProvider[]> {
  const directory = mkdtempSync(join(tmpdir(), "pi-providers-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  if (secretFiles) {
    assert.ok(typeof baseUrl === "string" && typeof apiKey === "string");
    writeFileSync(join(directory, "base-url"), baseUrl);
    writeFileSync(join(directory, "api-key"), apiKey);
    baseUrl = { _secret: join(directory, "base-url") };
    apiKey = { _secret: join(directory, "api-key") };
  }
  const config = join(directory, "providers.json");
  writeFileSync(
    config,
    JSON.stringify({
      test: {
        name: "Test Provider",
        baseUrl,
        apiKey,
        fallbackModels: ["text", "vision", "image"],
        defaults: {
          contextWindow: 256000,
          maxTokens: 32000,
        },
        imageModelMarkers: ["vision", "image"],
        nonReasoningModelMarkers: ["image"],
      },
    }),
  );

  const previous = process.env.PI_PROVIDERS_CONFIG;
  t.after(() => {
    if (previous === undefined) {
      delete process.env.PI_PROVIDERS_CONFIG;
    } else {
      process.env.PI_PROVIDERS_CONFIG = previous;
    }
  });
  process.env.PI_PROVIDERS_CONFIG = config;
  t.mock.method(globalThis, "fetch", async () => {
    throw new Error("Unexpected network request");
  });

  const source = new URL("../index.ts", import.meta.url);
  source.searchParams.set("fixture", directory);
  const imported: unknown = await import(source.href);
  assert.ok(
    typeof imported === "object" &&
      imported !== null &&
      "default" in imported &&
      typeof imported.default === "function",
  );
  const registrations: { id: string; definition: ProviderConfig }[] = [];
  const api: Pick<ExtensionAPI, "registerProvider"> = {
    registerProvider(provider: string | Provider, definition?: ProviderConfig) {
      assert.ok(typeof provider === "string" && definition);
      registrations.push({ id: provider, definition });
    },
  };
  Reflect.apply(imported.default, undefined, [api]);
  return registrations.map(({ id, definition }) => {
    const { models, refreshModels } = definition;
    assert.ok(models && refreshModels);
    return { id, definition: { ...definition, models, refreshModels } };
  });
}

test("reads secret files at runtime and strips only trailing line endings", async (t) => {
  const [registration] = await loadProvider(t, {
    baseUrl: "https://secret-provider.invalid\r\n",
    apiKey: " test-key \r\n",
    secretFiles: true,
  });
  assert.ok(registration);
  const { definition } = registration;
  assert.equal(definition.baseUrl, "https://secret-provider.invalid/v1");
  assert.equal(definition.apiKey, " test-key ");
  t.mock.method(
    globalThis,
    "fetch",
    async (url: Parameters<typeof fetch>[0], options?: RequestInit) => {
      assert.ok(options);
      assert.equal(url, "https://secret-provider.invalid/v1/models");
      assert.deepEqual(options.headers, { Authorization: "Bearer  test-key " });
      return Response.json({ data: [{ id: "secret-model" }] });
    },
  );
  assert.equal(
    (await definition.refreshModels(refreshContext()))[0]?.id,
    "secret-model",
  );
});

test("expands command substitutions in secret paths", async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "pi secret path with spaces-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(join(directory, "base-url"), "https://expanded.invalid\n");
  writeFileSync(join(directory, "api-key"), "expanded-test-key\n");

  const [registration] = await loadProvider(t, {
    baseUrl: {
      _secret: `$(printf '%s' '${directory}')/base-url`,
    },
    apiKey: {
      _secret: `$(printf '%s' '${directory}')/api-key`,
    },
  });
  assert.ok(registration);
  const { definition } = registration;
  assert.equal(definition.baseUrl, "https://expanded.invalid/v1");
  assert.equal(definition.apiKey, "expanded-test-key");
});

test("reports unreadable secret files", async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "pi-missing-secret-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  for (const field of ["baseUrl", "apiKey"]) {
    await t.test(field, async (subtest) => {
      await assert.rejects(
        loadProvider(subtest, { [field]: { _secret: join(directory, field) } }),
        { code: "ENOENT" },
      );
    });
  }
});

test("registers literal settings with fallback models and model capabilities", async (t) => {
  const registrations = await loadProvider(t);
  assert.equal(registrations.length, 1);
  const first = registrations[0];
  assert.ok(first);
  const { id, definition } = first;

  assert.equal(id, "test");
  assert.equal(definition.name, "Test Provider");
  assert.equal(definition.baseUrl, "https://provider.invalid/v1");
  assert.equal(definition.api, "openai-completions");
  assert.equal(definition.apiKey, "test-key");
  assert.deepEqual(
    definition.models.map((model) => {
      assert.ok(model.type === undefined || model.type === "chat");
      return {
        id: model.id,
        input: model.input,
        reasoning: model.reasoning,
        contextWindow: model.contextWindow,
        maxTokens: model.maxTokens,
      };
    }),
    [
      {
        id: "text",
        input: ["text"],
        reasoning: true,
        contextWindow: 256000,
        maxTokens: 32000,
      },
      {
        id: "vision",
        input: ["text", "image"],
        reasoning: true,
        contextWindow: 256000,
        maxTokens: 32000,
      },
      {
        id: "image",
        input: ["text", "image"],
        reasoning: false,
        contextWindow: 256000,
        maxTokens: 32000,
      },
    ],
  );
});

test("refreshes remote models and forwards authentication and cancellation", async (t) => {
  const [registration] = await loadProvider(t);
  assert.ok(registration);
  const { definition } = registration;
  const controller = new AbortController();
  t.mock.method(
    globalThis,
    "fetch",
    async (url: Parameters<typeof fetch>[0], options?: RequestInit) => {
      assert.ok(options);
      assert.equal(url, "https://provider.invalid/v1/models");
      assert.deepEqual(options.headers, { Authorization: "Bearer test-key" });
      assert.equal(options.signal, controller.signal);
      return Response.json({
        data: [
          { id: "new-vision", context_window: 128000, max_tokens: 8000 },
          { id: "new-image" },
        ],
      });
    },
  );

  const models = await definition.refreshModels(
    refreshContext(controller.signal),
  );
  assert.deepEqual(
    models.map((model) => model.id),
    ["new-vision", "new-image"],
  );
  assert.ok(models[0] && models[1]);
  assert.ok(models[0].type === undefined || models[0].type === "chat");
  assert.ok(models[1].type === undefined || models[1].type === "chat");
  assert.deepEqual(models[0].input, ["text", "image"]);
  assert.equal(models[0].contextWindow, 128000);
  assert.equal(models[0].maxTokens, 8000);
  assert.equal(models[1].contextWindow, 256000);
  assert.equal(models[1].maxTokens, 32000);
  assert.equal(models[1].reasoning, false);
});

test("omits authorization when no API key is configured", async (t) => {
  const [registration] = await loadProvider(t, { apiKey: "" });
  assert.ok(registration);
  const { definition } = registration;
  t.mock.method(
    globalThis,
    "fetch",
    async (_url: Parameters<typeof fetch>[0], options?: RequestInit) => {
      assert.ok(options);
      assert.deepEqual(options.headers, {});
      return Response.json({ data: [{ id: "local" }] });
    },
  );
  assert.equal(
    (await definition.refreshModels(refreshContext()))[0]?.id,
    "local",
  );
});

test("reports HTTP failures instead of accepting an unsuccessful catalog", async (t) => {
  const [registration] = await loadProvider(t);
  assert.ok(registration);
  const { definition } = registration;
  t.mock.method(
    globalThis,
    "fetch",
    async () => new Response("Unavailable", { status: 503 }),
  );
  await assert.rejects(
    definition.refreshModels(refreshContext()),
    /Failed to refresh test models: 503/,
  );
});

test("rejects malformed catalogs", async (t) => {
  const [registration] = await loadProvider(t);
  assert.ok(registration);
  const { definition } = registration;
  for (const [payload, message] of [
    [null, /catalog must be an object/],
    [{ data: [] }, /test.data must be a non-empty array/],
    [{ data: [{ id: "" }] }, /id must be a non-empty string/],
    [
      { data: [{ id: "model", context_window: 0 }] },
      /context_window must be a positive number/,
    ],
    [
      { data: [{ id: "model", max_tokens: -1 }] },
      /max_tokens must be a positive number/,
    ],
  ] as const) {
    await t.test(String(message), async (subtest) => {
      subtest.mock.method(globalThis, "fetch", async () =>
        Response.json(payload),
      );
      await assert.rejects(definition.refreshModels(refreshContext()), message);
    });
  }
});
