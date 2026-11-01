import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { loadProviderDefinitions } from "./definitions.ts";

export default function (pi: ExtensionAPI) {
  const providers = loadProviderDefinitions(
    new Set(getBuiltinModels("openai").map((model) => model.id)),
  );
  for (const [id, definition] of providers) {
    pi.registerProvider(id, definition);
  }
}
