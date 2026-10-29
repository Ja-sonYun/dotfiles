import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [sdk, profileDir, provider, model, ...args] = process.argv.slice(2);
const { ModelRuntime, parseArgs } = await import(pathToFileURL(sdk).href);
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
const runtime = await ModelRuntime.create({
  authPath: join(profileDir, "auth.json"),
  modelsPath: join(profileDir, "models.json"),
  modelsStorePath: join(profileDir, "models-store.json"),
});
if (!runtime.getModel(provider, model)) {
  await runtime.refresh({
    allowNetwork: true,
    signal: AbortSignal.timeout(15_000),
  });
  if (!runtime.getModel(provider, model)) {
    throw new Error(
      `Unknown Pi model after catalog refresh: ${provider}/${model}`,
    );
  }
}
