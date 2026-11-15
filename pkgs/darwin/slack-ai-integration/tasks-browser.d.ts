type TaskView = import("./contracts.mjs").TaskView;

interface Window {
  __slackAiTasksBridge(payload: string): void;
  __slackAiTasks?: {
    owner: string;
    pulse(owner: string): boolean;
    receive(tasks: TaskView[]): void;
    open(taskId?: string): void;
    close(): void;
    isOpen(): boolean;
    stop(): void;
  };
  __slackMessageReview?: {
    open(id: string): unknown;
    close(): void;
    has(id: string): boolean;
  };
}
