import { readFileSync, readdirSync } from "node:fs";
import { basename, join } from "node:path";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
import type { AgentConfig } from "./agents.ts";

function mcpServers(): string[] {
  if (!process.env.PI_MCP_CONFIG) return [];
  const config = JSON.parse(readFileSync(process.env.PI_MCP_CONFIG, "utf8"));
  if (
    !config ||
    typeof config !== "object" ||
    !config.mcpServers ||
    typeof config.mcpServers !== "object" ||
    Array.isArray(config.mcpServers)
  ) {
    throw new Error("PI_MCP_CONFIG must contain an mcpServers object");
  }
  const servers = Object.keys(config.mcpServers).sort(
    (a, b) => b.length - a.length,
  );
  const namespaces = servers.map((name) => name.replace(/[^A-Za-z0-9_]/g, "_"));
  if (new Set(namespaces).size !== servers.length) {
    throw new Error("MCP server names collide as Pi tool namespaces");
  }
  return servers;
}

function sourceTools(
  value: unknown,
  mode: unknown,
  servers: string[],
): string[] {
  let names: string[];
  if (typeof value === "string") {
    names = value.split(",");
  } else if (
    Array.isArray(value) &&
    value.every((name) => typeof name === "string")
  ) {
    names = value;
  } else {
    throw new Error("Agent tools must be a string or string list");
  }
  names = names.map((name) => name.trim()).filter(Boolean);
  if (!names.length)
    throw new Error("Agent tools must contain an MCP wildcard");
  const tools = ["read", "grep", "find", "ls", "codemode", "tool_search"];
  if (mode !== "plan") tools.push("bash", "edit", "write");
  for (const name of names) {
    let matched = false;
    for (const server of servers) {
      const prefix = [`mcp__plugin_hm_${server}__`, `mcp__${server}__`].find(
        (candidate) => name.startsWith(candidate),
      );
      if (!prefix) continue;
      if (name.slice(prefix.length) !== "*") {
        throw new Error(`Only MCP server wildcards are supported: ${name}`);
      }
      // Match Pi's native MCP namespace before the per-tool length limit.
      // https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/src/extensions/mcp/tools.ts
      tools.push(`mcp__${server.replace(/[^A-Za-z0-9_]/g, "_")}__*`);
      matched = true;
      break;
    }
    if (!matched) throw new Error(`Unknown MCP tool namespace: ${name}`);
  }
  return [...new Set(tools)];
}

export function loadSourceAgents(directory: string): AgentConfig[] {
  const servers = mcpServers();
  const { settings } = JSON.parse(
    readFileSync(
      new URL("../../config/defaults.json", import.meta.url),
      "utf8",
    ),
  );
  return readdirSync(directory, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.name.endsWith(".md") &&
        entry.name !== "README.md" &&
        (entry.isFile() || entry.isSymbolicLink()),
    )
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((entry): AgentConfig => {
      const filePath = join(directory, entry.name);
      const content = readFileSync(filePath, "utf8");
      const lines = content.split(/\r?\n/);
      if (
        lines[0].trim() !== "---" ||
        !lines.slice(1).some((line) => line.trim() === "---")
      ) {
        throw new Error(
          `Missing or unterminated agent frontmatter: ${filePath}`,
        );
      }
      const { frontmatter, body } =
        parseFrontmatter<Record<string, unknown>>(content);
      if (
        typeof frontmatter.name !== "string" ||
        !/^[a-z0-9][a-z0-9-]*$/.test(frontmatter.name) ||
        frontmatter.name !== basename(entry.name, ".md")
      ) {
        throw new Error(`Invalid agent name: ${filePath}`);
      }
      if (
        typeof frontmatter.description !== "string" ||
        !frontmatter.description
      ) {
        throw new Error(`Invalid agent description: ${filePath}`);
      }
      if (
        frontmatter.permissionMode != null &&
        frontmatter.permissionMode !== "default" &&
        frontmatter.permissionMode !== "plan"
      ) {
        throw new Error(`Invalid agent permissionMode: ${filePath}`);
      }
      if (
        frontmatter.model != null &&
        (typeof frontmatter.model !== "string" ||
          !["inherit", "xhigh", "high", "middle", "low"].includes(
            frontmatter.model,
          ))
      ) {
        throw new Error(`Invalid agent model tier: ${filePath}`);
      }
      return {
        name: frontmatter.name,
        description: frontmatter.description,
        model:
          frontmatter.model == null || frontmatter.model === "inherit"
            ? undefined
            : `${settings.defaultProvider}/${settings.defaultModel}:${settings.defaultThinkingLevel}`,
        permissionMode: frontmatter.permissionMode ?? undefined,
        tools:
          "tools" in frontmatter
            ? sourceTools(
                frontmatter.tools,
                frontmatter.permissionMode,
                servers,
              )
            : undefined,
        systemPrompt: body,
        source: "user",
        filePath,
      };
    });
}
