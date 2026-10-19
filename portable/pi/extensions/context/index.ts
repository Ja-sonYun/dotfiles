import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  if (!process.env.PI_CONTEXT_FILE) return;

  const path = resolve(process.env.PI_CONTEXT_FILE);
  const content = readFileSync(path, "utf8");
  pi.on("before_agent_start", (event) => {
    if (
      !event.systemPromptOptions.contextFiles.some((file) => file.path === path)
    ) {
      event.systemPromptOptions.contextFiles.unshift({ path, content });
    }
  });
}
