type Input = { text: string; source: string };

export class RequestContext {
  requests: string[] = [];
  unattributed = false;
  private inputs: Input[] = [];
  private immediate: Input | undefined;
  private starting: { prompt: string; input: Input | undefined } | undefined;

  reset(): void {
    this.requests = [];
    this.inputs = [];
    this.immediate = undefined;
    this.starting = undefined;
    this.unattributed = true;
  }

  input(
    event: Input & { streamingBehavior?: unknown },
    pending: boolean,
  ): void {
    if (!pending) this.inputs = [];
    const input = { text: event.text, source: event.source };
    if (event.streamingBehavior) this.inputs.push(input);
    else this.immediate = input;
  }

  start(prompt: string): void {
    this.starting = { prompt, input: this.immediate };
    this.immediate = undefined;
  }

  consume(text: string, pending: boolean): void {
    // Pi exposes input sources before expansion, but not on consumed messages.
    // https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/src/core/agent-session.ts
    let input: Input | undefined;
    if (
      this.starting &&
      (text === this.starting.prompt ||
        text.startsWith(`${this.starting.prompt}\n\n`))
    ) {
      input = this.starting.input;
    } else {
      const matches = this.inputs.filter(
        (candidate) => candidate.text === text,
      );
      if (new Set(matches.map((candidate) => candidate.source)).size === 1) {
        input = matches[0];
        if (input) this.inputs.splice(this.inputs.indexOf(input), 1);
      }
    }
    this.starting = undefined;
    if (!pending) this.inputs = [];
    if (input?.source === "extension") return;
    this.unattributed = !input;
    if (input) this.requests.push(input.text);
  }
}
