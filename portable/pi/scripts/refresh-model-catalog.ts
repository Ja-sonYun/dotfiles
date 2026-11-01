import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [
  sdk,
  builtinProviders,
  providerDefinitions,
  profileDir,
  provider,
  model,
  ...args
] = process.argv.slice(2);
if (
  sdk === undefined ||
  builtinProviders === undefined ||
  providerDefinitions === undefined ||
  profileDir === undefined ||
  provider === undefined ||
  model === undefined
) {
  throw new Error(
    "Expected SDK, builtin providers, provider definitions, profile directory, provider, and model arguments",
  );
}
const {
  ModelRuntime,
  parseArgs,
}: Pick<
  typeof import("@earendil-works/pi-coding-agent"),
  "ModelRuntime" | "parseArgs"
> = await import(pathToFileURL(sdk).href);
const requested = parseArgs(args);
if (
  requested.help ||
  requested.version ||
  (requested.provider && requested.provider !== provider) ||
  (requested.model &&
    requested.model !== model &&
    requested.model !== `${provider}/${model}`)
) {
  process.exit(0);
}
const {
  getBuiltinModels,
}: Pick<
  typeof import("@earendil-works/pi-ai/providers/all"),
  "getBuiltinModels"
> = await import(pathToFileURL(builtinProviders).href);
const {
  loadProviderDefinitions,
}: typeof import("../extensions/providers/definitions.ts") = await import(
  pathToFileURL(providerDefinitions).href
);
const definition = loadProviderDefinitions(
  new Set(getBuiltinModels("openai").map((model) => model.id)),
).get(provider);
if (definition) {
  const signal = AbortSignal.timeout(15_000);
  const models = await definition.refreshModels({ signal });
  signal.throwIfAborted();
  if (!models.some((entry) => entry.id === model)) {
    throw new Error(
      `Unknown Pi model after catalog refresh: ${provider}/${model}`,
    );
  }
  process.exit(0);
}
const runtime = await ModelRuntime.create({
  authPath: join(profileDir, "auth.json"),
  modelsPath: join(profileDir, "models.json"),
  modelsStorePath: join(profileDir, "models-store.json"),
});
if (!runtime.getModel(provider, model)) {
  const signal = AbortSignal.timeout(15_000);
  const result = await runtime.refresh({
    providers: [provider],
    allowNetwork: true,
    signal,
  });
  signal.throwIfAborted();
  if (result.aborted) {
    throw new Error(`Pi model catalog refresh aborted for ${provider}`);
  }
  const error = result.errors.get(provider);
  if (error) {
    throw new Error(`Failed to refresh Pi model catalog for ${provider}`, {
      cause: error,
    });
  }
  if (!runtime.getModel(provider, model)) {
    throw new Error(
      `Unknown Pi model after catalog refresh: ${provider}/${model}`,
    );
  }
}
