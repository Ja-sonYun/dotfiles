import os
import sys
import time
from collections.abc import Mapping
from contextvars import ContextVar
from dataclasses import dataclass, field


@dataclass
class HookContext:
    environment: dict[str, str]
    deadline: float
    stdout: list[str] = field(default_factory=list)
    stderr: list[str] = field(default_factory=list)
    evaluations: list[dict[str, object]] = field(default_factory=list)
    rules_decision: str | None = None


current: ContextVar[HookContext | None] = ContextVar("hook_context", default=None)


def environment() -> Mapping[str, str]:
    context = current.get()
    return os.environ if context is None else context.environment


def remaining(limit: float) -> float:
    context = current.get()
    return (
        limit
        if context is None
        else min(limit, max(0, context.deadline - time.monotonic()))
    )


def write_output(value: str, *, error: bool = False) -> None:
    context = current.get()
    if context is None:
        print(value, end="", file=sys.stderr if error else sys.stdout)
    else:
        (context.stderr if error else context.stdout).append(value)
