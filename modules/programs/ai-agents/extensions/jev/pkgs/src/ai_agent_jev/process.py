import asyncio
import base64
import os
import signal
from collections.abc import Awaitable, Sequence
from pathlib import Path


async def run_process(
    arguments: Sequence[str],
    cwd: Path,
    timeout: float,
    input_text: str | None = None,
    *,
    capture: dict[str, object] | None = None,
) -> str:
    creation = asyncio.create_task(
        asyncio.create_subprocess_exec(
            *arguments,
            cwd=cwd,
            stdin=asyncio.subprocess.PIPE
            if input_text is not None
            else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    )
    communication: asyncio.Task[tuple[bytes, bytes]] | None = None
    try:
        process = await asyncio.shield(creation)
        communication = asyncio.create_task(
            process.communicate(input_text.encode() if input_text is not None else None)
        )
        output, _ = await asyncio.wait_for(asyncio.shield(communication), timeout)
        if process.returncode:
            raise RuntimeError(f"Command exited with status {process.returncode}.")
        return output.decode("utf-8")
    finally:
        process = await creation
        if communication is None:
            communication = asyncio.create_task(process.communicate())
        if not communication.done():
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(asyncio.shield(communication), 2)
            except TimeoutError:
                pass
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        output, stderr = await communication
        if capture is not None:
            capture["exit_code"] = process.returncode
            for name, value in (("stdout", output), ("stderr", stderr)):
                try:
                    capture[name] = value.decode("utf-8")
                except UnicodeDecodeError:
                    capture[f"{name}_base64"] = base64.b64encode(value).decode("ascii")


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
