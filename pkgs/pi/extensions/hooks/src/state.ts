export type HookState = {
  notificationTimer: ReturnType<typeof setTimeout> | undefined;
  pendingPromptContext: string | undefined;
  stopContinuations: number;
  readonly toolRecords: Map<
    string,
    { readonly input: Readonly<Record<string, unknown>> }
  >;
};

export const createHookState = (): HookState => ({
  notificationTimer: undefined,
  pendingPromptContext: undefined,
  stopContinuations: 0,
  toolRecords: new Map(),
});

export const clearNotificationTimer = (state: HookState): void => {
  if (state.notificationTimer !== undefined) {
    clearTimeout(state.notificationTimer);
    state.notificationTimer = undefined;
  }
};
