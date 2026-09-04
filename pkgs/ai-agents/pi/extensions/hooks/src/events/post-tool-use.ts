import type {
  ExtensionAPI,
  ExtensionContext,
  ToolResultEvent,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  collectContext,
  commonInput,
  firstBlockReason,
  getSpecific,
  hiddenMessage,
  isRecord,
  reportError,
  shouldStop,
} from "../hook-contract.ts";

type ToolContent =
  | {
      readonly text: string;
      readonly textSignature?: string;
      readonly type: "text";
    }
  | {
      readonly data: string;
      readonly mimeType: string;
      readonly type: "image";
    };

type UsageValue = {
  readonly cacheRead: number;
  readonly cacheWrite: number;
  readonly cacheWrite1h?: number;
  readonly cost: {
    readonly cacheRead: number;
    readonly cacheWrite: number;
    readonly input: number;
    readonly output: number;
    readonly total: number;
  };
  readonly input: number;
  readonly output: number;
  readonly reasoning?: number;
  readonly totalTokens: number;
};

type ToolResultPatch = {
  content?: ToolContent[];
  details?: unknown;
  isError?: boolean;
  usage?: UsageValue;
};

const isToolContentArray = (value: unknown): value is ToolContent[] =>
  Array.isArray(value) &&
  value.every(
    (block) =>
      isRecord(block) &&
      ((block["type"] === "text" && typeof block["text"] === "string") ||
        (block["type"] === "image" &&
          typeof block["data"] === "string" &&
          typeof block["mimeType"] === "string")),
  );

const isUsageValue = (value: unknown): value is UsageValue => {
  if (!isRecord(value) || !isRecord(value["cost"])) {
    return false;
  }
  const cost = value["cost"];
  return (
    [
      value["input"],
      value["output"],
      value["cacheRead"],
      value["cacheWrite"],
      value["totalTokens"],
      cost["input"],
      cost["output"],
      cost["cacheRead"],
      cost["cacheWrite"],
      cost["total"],
    ].every((field) => typeof field === "number") &&
    (value["cacheWrite1h"] === undefined ||
      typeof value["cacheWrite1h"] === "number") &&
    (value["reasoning"] === undefined || typeof value["reasoning"] === "number")
  );
};

const parseToolPatch = (
  value: unknown,
  context: ExtensionContext,
): ToolResultPatch | undefined => {
  if (!isRecord(value)) {
    reportError(context, "PostToolUse updatedToolOutput must be an object.");
    return undefined;
  }
  const allowed = new Set(["content", "details", "isError", "usage"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    reportError(
      context,
      "PostToolUse updatedToolOutput has unsupported fields.",
    );
    return undefined;
  }
  if (value["content"] !== undefined && !isToolContentArray(value["content"])) {
    reportError(
      context,
      "PostToolUse updatedToolOutput.content must be an array.",
    );
    return undefined;
  }
  if (value["isError"] !== undefined && typeof value["isError"] !== "boolean") {
    reportError(
      context,
      "PostToolUse updatedToolOutput.isError must be boolean.",
    );
    return undefined;
  }
  if (value["usage"] !== undefined && !isUsageValue(value["usage"])) {
    reportError(
      context,
      "PostToolUse updatedToolOutput.usage must be an object.",
    );
    return undefined;
  }

  const patch: ToolResultPatch = {};
  if (isToolContentArray(value["content"])) {
    patch.content = value["content"];
  }
  if ("details" in value) {
    patch.details = value["details"];
  }
  if (typeof value["isError"] === "boolean") {
    patch.isError = value["isError"];
  }
  if (isUsageValue(value["usage"])) {
    patch.usage = value["usage"];
  }
  return patch;
};

export const runPostToolUse = async (
  pi: ExtensionAPI,
  event: ToolResultEvent,
  context: ExtensionContext,
): Promise<ToolResultPatch | undefined> => {
  const input = commonInput("PostToolUse", context);
  input["tool_input"] = event.input;
  input["tool_name"] = event.toolName;
  input["tool_use_id"] = event.toolCallId;
  const response: Record<string, unknown> = {
    content: event.content,
    isError: event.isError,
  };
  if (event.details !== undefined) {
    response["details"] = event.details;
  }
  if (event.usage !== undefined) {
    response["usage"] = event.usage;
  }
  input["tool_response"] = response;

  const results = await runHooks(
    pi,
    "PostToolUse",
    event.toolName,
    input,
    context,
  );
  const additionalContext = collectContext(results);
  if (additionalContext !== undefined) {
    pi.sendMessage(hiddenMessage(additionalContext), {
      deliverAs: "steer",
    });
  }

  const blockReason = firstBlockReason(results);
  if (blockReason !== undefined) {
    pi.sendMessage(hiddenMessage(blockReason), { deliverAs: "steer" });
  }
  if (shouldStop(results)) {
    context.abort();
  }

  const patchValues = results
    .map((result) => getSpecific(result.output)?.["updatedToolOutput"])
    .filter((value) => value !== undefined);
  if (patchValues.length > 1) {
    reportError(
      context,
      "Multiple PostToolUse hooks returned updatedToolOutput.",
    );
    return undefined;
  }
  return patchValues.length === 0
    ? undefined
    : parseToolPatch(patchValues[0], context);
};
