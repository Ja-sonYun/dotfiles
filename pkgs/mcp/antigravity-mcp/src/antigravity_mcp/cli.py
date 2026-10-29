import json
import os
import signal
import subprocess
from pathlib import Path

import anyio
from anyio.abc import ByteReceiveStream, Process
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations


async def collect(stream: ByteReceiveStream, chunks: list[bytes]) -> None:
    async for chunk in stream:
        chunks.append(chunk)


async def stop(process: Process) -> None:
    # Finish cleanup even when the MCP request has already been cancelled.
    with anyio.CancelScope(shield=True):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        else:
            with anyio.move_on_after(5):
                while True:
                    try:
                        os.killpg(process.pid, 0)
                    except ProcessLookupError:
                        await process.aclose()
                        return
                    await anyio.sleep(0.1)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        await process.aclose()


async def ask_antigravity(prompt: str, working_directory: str) -> str:
    if not prompt.strip():
        raise ToolError("Prompt must not be empty.")
    directory = Path(working_directory)
    if not directory.is_absolute() or not directory.is_dir():
        raise ToolError("Working directory must be an existing absolute directory.")
    executable = os.environ.get("ANTIGRAVITY_EXECUTABLE")
    if not executable:
        raise ToolError("ANTIGRAVITY_EXECUTABLE is not configured.")

    schema = {
        "type": "object",
        "properties": {"answer": {"type": "string"}},
        "required": ["answer"],
        "additionalProperties": False,
    }
    stdout: list[bytes] = []
    stderr: list[bytes] = []
    try:
        process = await anyio.open_process(
            [
                executable,
                "--print",
                prompt,
                "--output-format",
                "json",
                "--json-schema",
                json.dumps(schema),
                "--disable-slash-commands",
                "--print-timeout",
                "300s",
            ],
            cwd=directory,
            env={**os.environ, "AI_AGENT_SUBAGENT": "1"},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as error:
        raise ToolError(f"Could not start Antigravity: {error}") from error

    try:
        with anyio.fail_after(310):
            async with anyio.create_task_group() as group:
                if process.stdout is not None:
                    group.start_soon(collect, process.stdout, stdout)
                if process.stderr is not None:
                    group.start_soon(collect, process.stderr, stderr)
                returncode = await process.wait()
    except TimeoutError as error:
        raise ToolError("Antigravity timed out.") from error
    finally:
        await stop(process)

    if returncode != 0:
        detail = b"".join(stderr).decode("utf-8", errors="replace").strip()
        raise ToolError(f"Antigravity exited with code {returncode}: {detail}")
    try:
        result = json.loads(b"".join(stdout))
    except (ValueError, UnicodeDecodeError) as error:
        raise ToolError("Antigravity returned invalid JSON.") from error
    if not isinstance(result, dict):
        raise ToolError("Antigravity returned an invalid response.")
    if result.get("error") or result.get("is_error"):
        raise ToolError(f"Antigravity failed: {result.get('error', result)}")
    if result.get("denied_actions"):
        raise ToolError(
            "Antigravity could not complete the request: actions were denied."
        )
    output = result.get("structured_output")
    if not isinstance(output, dict):
        raise ToolError("Antigravity returned no structured answer.")
    answer = output.get("answer")
    if not isinstance(answer, str) or not answer.strip():
        raise ToolError("Antigravity returned an empty or invalid answer.")
    return answer


def main() -> None:
    server = FastMCP(
        "antigravity",
        instructions=(
            "Ask Antigravity to perform a task in an explicit working directory. "
            "Pass the user's scope and constraints in the prompt. Calls can use tools "
            "and modify files under Antigravity's configured permissions; calling this "
            "server does not grant additional authorization. Each call starts a new "
            "session with a five-minute execution limit."
        ),
        log_level="ERROR",
    )
    server.tool(
        name="ask_antigravity",
        description=(
            "Send a prompt to Antigravity in an existing absolute working_directory "
            "and return its answer. Include all necessary context and constraints."
        ),
        annotations=ToolAnnotations(
            readOnlyHint=False,
            destructiveHint=True,
            idempotentHint=False,
            openWorldHint=True,
        ),
    )(ask_antigravity)
    server.run(transport="stdio")
