import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import { commonInput, type AssistantResult } from "../hook-contract.ts";

const stopFailureKind = (message: string): string => {
  const normalized = message.toLowerCase();
  if (
    /oauth.*organi[sz]ation.*not allowed|oauth_org_not_allowed/.test(normalized)
  ) {
    return "oauth_org_not_allowed";
  }
  if (/rate.?limit|\b429\b/.test(normalized)) {
    return "rate_limit";
  }
  if (/overload|\b529\b/.test(normalized)) {
    return "overloaded";
  }
  if (
    /unauthori[sz]ed|authentication|invalid api key|\b401\b/.test(normalized)
  ) {
    return "authentication_failed";
  }
  if (/billing|payment required|credit balance|\b402\b/.test(normalized)) {
    return "billing_error";
  }
  if (/model.*not found|model_not_found/.test(normalized)) {
    return "model_not_found";
  }
  if (
    /max(?:imum)? output token|max_output_tokens|output token.*limit/.test(
      normalized,
    )
  ) {
    return "max_output_tokens";
  }
  if (/invalid request|invalid_request|bad request|\b400\b/.test(normalized)) {
    return "invalid_request";
  }
  if (
    /server error|server_error|internal server|\b50[0234]\b/.test(normalized)
  ) {
    return "server_error";
  }
  return "unknown";
};

export const runStopFailure = async (
  pi: ExtensionAPI,
  assistant: AssistantResult,
  context: ExtensionContext,
): Promise<void> => {
  const input = commonInput("StopFailure", context);
  const errorMessage =
    assistant.errorMessage ??
    (assistant.text === "" ? "Unknown provider error." : assistant.text);
  const error = stopFailureKind(errorMessage);
  input["error"] = error;
  input["error_details"] = errorMessage;
  input["last_assistant_message"] = errorMessage;
  await runHooks(pi, "StopFailure", error, input, context);
};
