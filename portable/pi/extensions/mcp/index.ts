import { readFileSync } from "node:fs";
import type {
  ExtensionAPI,
  McpServerConfig,
} from "@earendil-works/pi-coding-agent";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export default function (pi: ExtensionAPI) {
  if (!process.env.PI_MCP_CONFIG) return;

  const config: unknown = JSON.parse(
    readFileSync(process.env.PI_MCP_CONFIG, "utf8"),
  );
  if (!isRecord(config) || !isRecord(config.mcpServers)) {
    throw new Error("PI_MCP_CONFIG must contain an mcpServers object");
  }

  for (const [name, value] of Object.entries(config.mcpServers)) {
    if (!isRecord(value)) {
      throw new Error(`MCP server ${name} must be an object`);
    }
    const { instructions, disabled, ...server } = value;
    if (disabled !== undefined) {
      if (
        typeof disabled !== "boolean" ||
        (server.enabled !== undefined && server.enabled !== !disabled)
      ) {
        throw new Error(
          `MCP server ${name} has invalid enabled/disabled flags`,
        );
      }
      server.enabled = !disabled;
    }
    if (instructions !== undefined && instructions !== null) {
      if (
        typeof instructions !== "string" ||
        typeof server.command !== "string" ||
        server.url !== undefined ||
        (server.args !== undefined &&
          (!Array.isArray(server.args) ||
            !server.args.every((arg) => typeof arg === "string")))
      ) {
        throw new Error(
          `MCP server ${name}: instructions require a stdio command and string arguments`,
        );
      }
      server.args = [
        "--instructions",
        instructions,
        "--",
        server.command,
        ...(server.args ?? []),
      ];
      server.command = "pi-mcp-instructions";
    }

    // Native registration validates the remaining transport and authentication fields.
    pi.registerMcpServer(name, server as unknown as McpServerConfig);
  }
}
