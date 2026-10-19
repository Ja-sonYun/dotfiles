import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";
import type {
  ExtensionAPI,
  ProviderModelConfig,
} from "@earendil-works/pi-coding-agent";

type RawModel = {
  readonly id: string;
  readonly context_window?: number;
  readonly max_tokens?: number;
};

type SecretValue = string | { readonly _secret: string };

type ProviderDefinition = {
  readonly name: string;
  readonly baseUrl: SecretValue;
  readonly apiKey: SecretValue;
  readonly fallbackModels: ReadonlyArray<string>;
  readonly excludeOpenAIModels: boolean;
  readonly defaults: {
    readonly contextWindow: number;
    readonly maxTokens: number;
  };
  readonly imageModelMarkers: ReadonlyArray<string>;
  readonly nonReasoningModelMarkers: ReadonlyArray<string>;
};

type Providers = Readonly<Record<string, ProviderDefinition>>;

const resolveSecret = (value: SecretValue): string =>
  typeof value === "string"
    ? value
    : readFileSync(
        execFileSync("/bin/sh", ["-c", `printf '%s' "${value._secret}"`], {
          encoding: "utf8",
        }),
        "utf8",
      ).replace(/[\r\n]+$/, "");

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isUnknownArray = (value: unknown): value is unknown[] =>
  Array.isArray(value);

const readString = (value: unknown, path: string): string => {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${path} must be a non-empty string`);
  }
  return value;
};

const readPositiveNumber = (value: unknown, path: string): number => {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new Error(`${path} must be a positive number`);
  }
  return value;
};

const readRawModels = (
  value: unknown,
  path: string,
): ReadonlyArray<RawModel> => {
  if (!isUnknownArray(value) || value.length === 0) {
    throw new Error(`${path} must be a non-empty array`);
  }
  return value.map((entry, index) => {
    const modelPath = `${path}[${index}]`;
    if (!isRecord(entry)) {
      throw new Error(`${modelPath} must be an object`);
    }
    return {
      id: readString(entry.id, `${modelPath}.id`),
      ...(entry.context_window === undefined
        ? {}
        : {
            context_window: readPositiveNumber(
              entry.context_window,
              `${modelPath}.context_window`,
            ),
          }),
      ...(entry.max_tokens === undefined
        ? {}
        : {
            max_tokens: readPositiveNumber(
              entry.max_tokens,
              `${modelPath}.max_tokens`,
            ),
          }),
    };
  });
};

const providerPresets = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../../config/defaults.json"),
    "utf8",
  ),
).providers as Readonly<Record<string, Partial<ProviderDefinition>>>;
const configuredProviders: Providers = process.env.PI_PROVIDERS_CONFIG
  ? JSON.parse(readFileSync(process.env.PI_PROVIDERS_CONFIG, "utf8"))
  : {};
const providers = Object.fromEntries(
  Object.entries(configuredProviders).map(([id, provider]) => [
    id,
    {
      ...providerPresets[id],
      ...provider,
      defaults: {
        ...providerPresets[id]?.defaults,
        ...provider.defaults,
      },
    },
  ]),
);

const toModel = (
  model: RawModel,
  provider: ProviderDefinition,
): ProviderModelConfig => ({
  id: model.id,
  name: model.id,
  reasoning: !provider.nonReasoningModelMarkers.some((marker) =>
    model.id.includes(marker),
  ),
  input: provider.imageModelMarkers.some((marker) => model.id.includes(marker))
    ? ["text", "image"]
    : ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: model.context_window ?? provider.defaults.contextWindow,
  maxTokens: model.max_tokens ?? provider.defaults.maxTokens,
});

export default function (pi: ExtensionAPI) {
  const openAIModelIds = new Set(
    getBuiltinModels("openai").map((model) => model.id),
  );

  for (const [id, provider] of Object.entries(providers)) {
    const baseUrl = `${resolveSecret(provider.baseUrl)}/v1`;
    const key = resolveSecret(provider.apiKey);
    pi.registerProvider(id, {
      name: provider.name,
      baseUrl,
      apiKey: key,
      api: "openai-completions",
      models: provider.fallbackModels
        .filter(
          (id) => !provider.excludeOpenAIModels || !openAIModelIds.has(id),
        )
        .map((id) => toModel({ id }, provider)),
      async refreshModels({ signal }) {
        const response = await fetch(`${baseUrl}/models`, {
          headers: key ? { Authorization: `Bearer ${key}` } : {},
          signal,
        });
        if (!response.ok) {
          throw new Error(`Failed to refresh ${id} models: ${response.status}`);
        }
        const payload: unknown = await response.json();
        if (!isRecord(payload)) {
          throw new Error(`${id} model catalog must be an object`);
        }
        return readRawModels(payload.data, `${id}.data`)
          .filter(
            (model) =>
              !provider.excludeOpenAIModels || !openAIModelIds.has(model.id),
          )
          .map((model) => toModel(model, provider));
      },
    });
  }
}
