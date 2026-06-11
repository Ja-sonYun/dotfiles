/**
 * Hide pi-mcp-adapter's footer status while keeping MCP tools available.
 *
 * Pi's default footer renders every ctx.ui.setStatus() entry on a third line.
 * pi-mcp-adapter uses the key "mcp", so this custom footer mirrors the default
 * footer but filters that one status key out.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const HIDDEN_STATUS_KEYS = new Set(["mcp"]);

function sanitizeStatusText(text: string): string {
  return text
    .replace(/[\r\n\t]/g, " ")
    .replace(/ +/g, " ")
    .trim();
}

function formatTokens(count: number): string {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
  return `${Math.round(count / 1000000)}M`;
}

function formatCwdForFooter(cwd: string, home: string | undefined): string {
  if (!home) return cwd;

  const resolvedCwd = resolve(cwd);
  const resolvedHome = resolve(home);
  const relativeToHome = relative(resolvedHome, resolvedCwd);
  const isInsideHome =
    relativeToHome === "" ||
    (relativeToHome !== ".." &&
      !relativeToHome.startsWith(`..${sep}`) &&
      !isAbsolute(relativeToHome));

  if (!isInsideHome) return cwd;
  return relativeToHome === "" ? "~" : `~${sep}${relativeToHome}`;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setFooter((tui, theme, footerData) => {
      const unsubscribe = footerData.onBranchChange(() => tui.requestRender());

      return {
        dispose: unsubscribe,
        invalidate() {},
        render(width: number): string[] {
          let totalInput = 0;
          let totalOutput = 0;
          let totalCacheRead = 0;
          let totalCacheWrite = 0;
          let totalCost = 0;
          let latestCacheHitRate: number | undefined;

          for (const entry of ctx.sessionManager.getEntries()) {
            if (entry.type !== "message" || entry.message.role !== "assistant") continue;

            const usage = entry.message.usage;
            totalInput += usage.input;
            totalOutput += usage.output;
            totalCacheRead += usage.cacheRead;
            totalCacheWrite += usage.cacheWrite;
            totalCost += usage.cost.total;

            const latestPromptTokens = usage.input + usage.cacheRead + usage.cacheWrite;
            latestCacheHitRate =
              latestPromptTokens > 0 ? (usage.cacheRead / latestPromptTokens) * 100 : undefined;
          }

          const contextUsage = ctx.getContextUsage();
          const contextWindow = contextUsage?.contextWindow ?? ctx.model?.contextWindow ?? 0;
          const contextPercentValue = contextUsage?.percent ?? 0;
          const contextPercent = contextUsage?.percent !== null ? contextPercentValue.toFixed(1) : "?";

          let pwd = formatCwdForFooter(ctx.cwd, process.env.HOME || process.env.USERPROFILE);
          const branch = footerData.getGitBranch();
          if (branch) pwd = `${pwd} (${branch})`;

          const sessionName = ctx.sessionManager.getSessionName();
          if (sessionName) pwd = `${pwd} • ${sessionName}`;

          const statsParts: string[] = [];
          if (totalInput) statsParts.push(`↑${formatTokens(totalInput)}`);
          if (totalOutput) statsParts.push(`↓${formatTokens(totalOutput)}`);
          if (totalCacheRead) statsParts.push(`R${formatTokens(totalCacheRead)}`);
          if (totalCacheWrite) statsParts.push(`W${formatTokens(totalCacheWrite)}`);
          if ((totalCacheRead > 0 || totalCacheWrite > 0) && latestCacheHitRate !== undefined) {
            statsParts.push(`CH${latestCacheHitRate.toFixed(1)}%`);
          }

          const modelRegistry = ctx.modelRegistry as unknown as {
            isUsingOAuth?: (model: unknown) => boolean;
          };
          const usingSubscription = ctx.model ? modelRegistry.isUsingOAuth?.(ctx.model) ?? false : false;
          if (totalCost || usingSubscription) {
            statsParts.push(`$${totalCost.toFixed(3)}${usingSubscription ? " (sub)" : ""}`);
          }

          const autoIndicator = " (auto)";
          const contextPercentDisplay =
            contextPercent === "?"
              ? `?/${formatTokens(contextWindow)}${autoIndicator}`
              : `${contextPercent}%/${formatTokens(contextWindow)}${autoIndicator}`;
          if (contextPercentValue > 90) {
            statsParts.push(theme.fg("error", contextPercentDisplay));
          } else if (contextPercentValue > 70) {
            statsParts.push(theme.fg("warning", contextPercentDisplay));
          } else {
            statsParts.push(contextPercentDisplay);
          }

          let statsLeft = statsParts.join(" ");
          let statsLeftWidth = visibleWidth(statsLeft);
          if (statsLeftWidth > width) {
            statsLeft = truncateToWidth(statsLeft, width, "...");
            statsLeftWidth = visibleWidth(statsLeft);
          }

          const modelName = ctx.model?.id || "no-model";
          let rightSideWithoutProvider = modelName;
          if (ctx.model?.reasoning) {
            const thinkingLevel = pi.getThinkingLevel() || "off";
            rightSideWithoutProvider =
              thinkingLevel === "off" ? `${modelName} • thinking off` : `${modelName} • ${thinkingLevel}`;
          }

          let rightSide = rightSideWithoutProvider;
          if (footerData.getAvailableProviderCount() > 1 && ctx.model) {
            rightSide = `(${ctx.model.provider}) ${rightSideWithoutProvider}`;
            if (statsLeftWidth + 2 + visibleWidth(rightSide) > width) {
              rightSide = rightSideWithoutProvider;
            }
          }

          const rightSideWidth = visibleWidth(rightSide);
          const minPadding = 2;
          let statsLine: string;
          if (statsLeftWidth + minPadding + rightSideWidth <= width) {
            statsLine = statsLeft + " ".repeat(width - statsLeftWidth - rightSideWidth) + rightSide;
          } else {
            const availableForRight = width - statsLeftWidth - minPadding;
            if (availableForRight > 0) {
              const truncatedRight = truncateToWidth(rightSide, availableForRight, "");
              statsLine =
                statsLeft +
                " ".repeat(Math.max(0, width - statsLeftWidth - visibleWidth(truncatedRight))) +
                truncatedRight;
            } else {
              statsLine = statsLeft;
            }
          }

          const dimStatsLeft = theme.fg("dim", statsLeft);
          const dimRemainder = theme.fg("dim", statsLine.slice(statsLeft.length));
          const lines = [
            truncateToWidth(theme.fg("dim", pwd), width, theme.fg("dim", "...")),
            dimStatsLeft + dimRemainder,
          ];

          const statusLine = Array.from(footerData.getExtensionStatuses().entries())
            .filter(([key]) => !HIDDEN_STATUS_KEYS.has(key))
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([, text]) => sanitizeStatusText(text))
            .join(" ");

          if (statusLine) {
            lines.push(truncateToWidth(statusLine, width, theme.fg("dim", "...")));
          }

          return lines;
        },
      };
    });
  });
}
