import {
  createBashToolDefinition,
  createLocalBashOperations,
  createReadToolDefinition,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { createRedactedOperations } from "./execution.ts";
import { redact as redactBuffer } from "../../redaction/index.ts";

export default function redact(pi: ExtensionAPI) {
  const operations = createRedactedOperations(createLocalBashOperations());
  pi.registerTool(createBashToolDefinition(process.cwd(), { operations }));
  pi.on("user_bash", async () => ({ operations }));

  const read = createReadToolDefinition(process.cwd());
  pi.registerTool({
    ...read,
    async execute(toolCallId, input, signal, onUpdate, context) {
      const result = await read.execute(
        toolCallId,
        input,
        signal,
        onUpdate,
        context,
      );
      const content = await Promise.all(
        result.content.map(async (block) => {
          if (block.type !== "text") return block;
          const output = await redactBuffer(Buffer.from(block.text), signal);
          return { ...block, text: output.toString("utf8") };
        }),
      );
      if (signal?.aborted) throw new Error("aborted");

      // Codemode consumes structuredContent instead of the displayed text blocks.
      // https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/read.ts
      const note = content.find((block) => block.type === "text")?.text ?? "";
      const image = content.find((block) => block.type === "image");
      return {
        ...result,
        content,
        structuredContent: image
          ? { type: "image", data: image.data, mimeType: image.mimeType, note }
          : note,
      };
    },
  });
}
