type ConversationDestination =
  import("./contracts.mjs").ConversationDestination;

interface Window {
  desktopDelegates?: Record<
    string,
    { handleDeepLinkWithArgs(payload: string): unknown } | undefined
  >;
}

function navigateToConversation(destination: ConversationDestination): void {
  const workspace = location.pathname.match(
    /^\/client\/(T[A-Z0-9]+)(?:\/|$)/,
  )?.[1];
  if (workspace !== destination.workspaceId)
    throw new Error("Open the original workspace before opening this task.");
  const delegate = window.desktopDelegates?.[destination.workspaceId];
  if (typeof delegate?.handleDeepLinkWithArgs !== "function")
    throw new Error(
      "Slack conversation navigation is unavailable. Retry this task.",
    );
  delegate.handleDeepLinkWithArgs(
    JSON.stringify({
      cmd: "channel",
      team: destination.workspaceId,
      id: destination.channelId,
      ...(destination.threadTs ? { thread_ts: destination.threadTs } : {}),
    }),
  );
}
