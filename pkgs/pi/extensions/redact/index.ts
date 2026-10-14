import {
  createBashToolDefinition,
  createLocalBashOperations,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { createRedactedOperations } from "./execution.ts";

export default function redact(pi: ExtensionAPI) {
  const operations = createRedactedOperations(
    createLocalBashOperations(),
    process.env.PI_REDACT_EXECUTABLE,
  );
  pi.registerTool(createBashToolDefinition(process.cwd(), { operations }));
  pi.on("user_bash", async () => ({ operations }));
}
