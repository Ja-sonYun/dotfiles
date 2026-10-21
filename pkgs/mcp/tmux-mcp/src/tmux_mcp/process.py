import asyncio
import os
import signal


class RequestError(Exception):
    """An expected failure containing only an application-authored safe message."""


async def stop_process(process: asyncio.subprocess.Process) -> None:
    """Terminate the owned process group and reap its leader."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        await process.wait()
        return

    deadline = asyncio.get_running_loop().time() + 1
    while asyncio.get_running_loop().time() < deadline:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        await asyncio.sleep(0.05)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    await process.wait()


async def run_process(
    args: list[str],
    *,
    limit: int,
    timeout: int = 10,
    input_data: bytes | None = None,
) -> bytes:
    """Buffer bounded output without publishing child diagnostics."""
    try:
        process = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE
            if input_data is not None
            else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        raise RequestError(
            "Cannot start the required program; output withheld."
        ) from None

    try:
        async with asyncio.timeout(timeout):
            if input_data is not None and process.stdin is not None:
                process.stdin.write(input_data)
                await process.stdin.drain()
                process.stdin.close()

            output = bytearray()
            if process.stdout is None:
                raise RequestError("Cannot read program output.")
            while chunk := await process.stdout.read(
                min(65536, limit - len(output) + 1)
            ):
                output.extend(chunk)
                if len(output) > limit:
                    raise RequestError(
                        "Output exceeds the input limit; output withheld."
                    )
            await process.wait()
    except (asyncio.CancelledError, OSError, TimeoutError, RequestError) as error:
        cleanup = asyncio.create_task(stop_process(process))
        await asyncio.shield(cleanup)
        if isinstance(error, asyncio.CancelledError):
            raise
        if isinstance(error, RequestError):
            raise
        raise RequestError(
            "Program interrupted or timed out; output withheld. Do not retry key input automatically."
        ) from None

    if process.returncode != 0:
        raise RequestError(
            "Program failed; output withheld. Key input may be partial; do not retry automatically."
        )
    return bytes(output)
