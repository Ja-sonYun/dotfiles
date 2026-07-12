import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface RawModel {
  id: string;
  context_window?: number;
  max_tokens?: number;
}

export default async function (pi: ExtensionAPI) {
  const base = process.env.LLM_DOMAIN;
  const key = process.env.CAPI_KEY;
  if (!base) return;

  let raw: RawModel[] = [{ id: "gpt-5.4" }];
  try {
    const res = await fetch(`${base}/v1/models`, {
      headers: key ? { Authorization: `Bearer ${key}` } : {},
    });
    if (res.ok) {
      const payload = (await res.json()) as { data?: RawModel[] };
      if (payload.data?.length) raw = payload.data;
    }
  } catch {
    // LMP unreachable at startup: keep the fallback so the provider still exists.
  }

  pi.registerProvider("lmp", {
    name: "LMP",
    baseUrl: `${base}/v1`,
    apiKey: "$CAPI_KEY",
    api: "openai-completions",
    models: raw.map((m) => ({
      id: m.id,
      name: m.id,
      reasoning: !/image/.test(m.id),
      input: (/vision|image/.test(m.id) ? ["text", "image"] : ["text"]) as (
        | "text"
        | "image"
      )[],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: m.context_window ?? 256000,
      maxTokens: m.max_tokens ?? 32000,
    })),
  });
}
