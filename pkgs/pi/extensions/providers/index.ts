import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ProviderModelConfig,
} from "@earendil-works/pi-coding-agent";

type RawModel = {
  readonly id: string;
  readonly context_window?: number;
  readonly max_tokens?: number;
};

type ProviderDefinition = {
  readonly name: string;
  readonly baseUrlEnv: string;
  readonly apiKeyEnv: string;
  readonly fallbackModels: ReadonlyArray<string>;
  readonly defaults: {
    readonly contextWindow: number;
    readonly maxTokens: number;
  };
  readonly imageModelMarkers: ReadonlyArray<string>;
  readonly nonReasoningModelMarkers: ReadonlyArray<string>;
};

type Providers = Readonly<Record<string, ProviderDefinition>>;

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

const configPath = join(
  dirname(fileURLToPath(import.meta.url)),
  "providers.json",
);
const providers = JSON.parse(readFileSync(configPath, "utf8")) as Providers;

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
  for (const [id, provider] of Object.entries(providers)) {
    const base = process.env[provider.baseUrlEnv];
    if (!base) continue;

    const baseUrl = `${base}/v1`;
    const key = process.env[provider.apiKeyEnv];
    pi.registerProvider(id, {
      name: provider.name,
      baseUrl,
      apiKey: `$${provider.apiKeyEnv}`,
      api: "openai-completions",
      models: provider.fallbackModels.map((id) => toModel({ id }, provider)),
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
        return readRawModels(payload.data, `${id}.data`).map((model) =>
          toModel(model, provider),
        );
      },
    });
  }
}
