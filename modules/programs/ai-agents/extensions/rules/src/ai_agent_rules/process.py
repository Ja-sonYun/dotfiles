import asyncio
import os
import signal
import time
from collections.abc import Awaitable, Sequence
from pathlib import Path

import psutil

from ai_agent_rules.context import environment, remaining


def group_members(group: int) -> list[psutil.Process]:
    members = []
    for process in psutil.process_iter():
        try:
            if os.getpgid(process.pid) == group:
                process.create_time()
                members.append(process)
        except (OSError, psutil.Error):
            continue
    return members


def group_alive(group: int, members: list[psutil.Process]) -> bool:
    for process in members:
        try:
            if (
                process.is_running()
                and process.status() != psutil.STATUS_ZOMBIE
                and os.getpgid(process.pid) == group
            ):
                return True
        except (OSError, psutil.Error):
            continue
    return False


async def run_process(
    arguments: Sequence[str],
    cwd: Path,
    timeout: float,
    *,
    input_text: str | None = None,
) -> tuple[int, str, str]:
    creation = asyncio.create_task(
        asyncio.create_subprocess_exec(
            *arguments,
            cwd=cwd,
            env=environment(),
            stdin=asyncio.subprocess.PIPE
            if input_text is not None
            else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    )
    communication: asyncio.Task[tuple[bytes, bytes]] | None = None
    completed = False
    try:
        process = await asyncio.shield(creation)
        communication = asyncio.create_task(
            process.communicate(input_text.encode() if input_text is not None else None)
        )
        output, errors = await asyncio.wait_for(
            asyncio.shield(communication), remaining(timeout)
        )
        completed = True
        return (
            process.returncode or 0,
            output.decode("utf-8", errors="replace"),
            errors.decode("utf-8", errors="replace"),
        )
    finally:

        async def finish() -> None:
            process = await creation
            if not completed:
                drain = communication or asyncio.create_task(process.communicate())
                members = group_members(process.pid)
                if group_alive(process.pid, members):
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                deadline = time.monotonic() + 2
                # Retain process identities so a reused group ID is never the sole
                # reason for sending a later signal after the leader exits.
                while group_alive(process.pid, members):
                    if time.monotonic() >= deadline:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        break
                    members = group_members(process.pid)
                    await asyncio.sleep(0.05)
                await drain

        cleanup = asyncio.create_task(finish())
        try:
            await asyncio.shield(cleanup)
        except asyncio.CancelledError:
            await cleanup
            raise


async def with_termination(awaitable: Awaitable[None]) -> None:
    loop = asyncio.get_running_loop()
    task = asyncio.current_task()
    if task is None:
        raise RuntimeError("Missing asyncio task.")
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def cancel_once() -> None:
        if not task.cancelling():
            task.cancel()

    for signum in signals:
        loop.add_signal_handler(signum, cancel_once)
    try:
        await awaitable
    finally:
        for signum in signals:
            loop.remove_signal_handler(signum)
