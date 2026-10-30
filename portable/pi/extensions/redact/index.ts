import {
  createBashToolDefinition,
  createLocalBashOperations,
  createReadToolDefinition,
  createGrepToolDefinition,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { createRedactedOperations } from "./execution.ts";
import { redact as redactBuffer } from "../../redaction/index.ts";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";

async function redactContent(
  content: AgentToolResult<unknown>["content"],
  signal?: AbortSignal,
) {
  return Promise.all(
    content.map(async (block) => {
      if (block.type !== "text") return block;
      const output = await redactBuffer(Buffer.from(block.text), signal);
      return { ...block, text: output.toString("utf8") };
    }),
  );
}

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
      const content = await redactContent(result.content, signal);
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
  const grep = createGrepToolDefinition(process.cwd());
  pi.registerTool({
    ...grep,
    async execute(toolCallId, input, signal, onUpdate, context) {
      const result = await grep.execute(
        toolCallId,
        input,
        signal,
        onUpdate,
        context,
      );
      const content = await redactContent(result.content, signal);
      signal?.throwIfAborted();
      return {
        ...result,
        content,
        structuredContent: content
          .filter((block) => block.type === "text")
          .map((block) => block.text)
          .join("\n"),
      };
    },
  });
}
