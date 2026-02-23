#!python

import asyncio
import os
import sys

import openai
from pydantic import BaseModel

api_key = os.environ.get("CAPI_KEY")

all_args = sys.argv[1:]
input_text = " ".join(all_args)


class CommandGrammarFixer(BaseModel):
    command: str


async def generate() -> str:
    client = openai.AsyncClient(
        base_url="https://lmp.test0.zip/v1",
        api_key=api_key,

    )
    response = await client.beta.chat.completions.parse(
        model="gpt-5.3-codex-spark",
        reasoning_effort="low",
        messages=[
            {
                "role": "system",
                "content": (
                    "You are an assistant that fixes grammar in shell commands. "
                    "If the input is not a command, respond with an error message. "
                    "If you can make it better, do so."
                ),
            },
            {"role": "user", "content": input_text},
        ],
        response_format=CommandGrammarFixer,
    )
    if (event := response.choices[0].message.parsed) is None:
        print("The input was not recognized as a valid shell command.", file=sys.stderr)
        sys.exit(1)

    return event.command.strip()


if __name__ == "__main__":
    print(asyncio.run(generate()))
