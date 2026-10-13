import json
import os
import tempfile
import unittest
from pathlib import Path
from typing import Literal
from unittest.mock import patch

import httpx
from ai_agent_rules.cli import Request, check


def rule(target: str, **changes: object) -> dict[str, object]:
    return {
        "target": target,
        "check": {"regex": "forbidden"},
        "why": "Test constraint",
        "message": "Change the proposed call",
        **changes,
    }


class CliTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="rules-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.rules = self.root / "static.json"
        self.rules.write_text("{}", encoding="utf-8")
        self.calls: list[dict[str, object]] = []
        self.verdict = "compliant"
        self.status = 200

        async def redact(
            *args: object, input_text: str, **kwargs: object
        ) -> tuple[int, str, str]:
            return 0, input_text, ""

        self.redaction = patch("ai_agent_rules.checks.run_process", side_effect=redact)
        self.redaction.start()
        self.addCleanup(self.redaction.stop)
        self.environment = patch.dict(
            os.environ,
            {
                "TYPESAFE_API_KEY": "fixture-key",
                "XDG_CACHE_HOME": str(self.root / "cache"),
            },
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def response(self, request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        self.calls.append(payload)
        return httpx.Response(
            self.status,
            json={
                "model": "jev-test",
                "answers": {
                    name: {"type": "choice", "choice": self.verdict}
                    for name in payload["questions"]
                },
            },
        )

    async def inspect(
        self,
        tool: str = "bash",
        inputs: dict[str, object] | None = None,
        *,
        client: Literal["codex", "claude", "pi"] = "codex",
        context: dict[str, object] | None = None,
        additional: dict[str, object] | None = None,
    ) -> dict[str, object]:
        request = Request(
            client=client,
            cwd=str(self.root),
            tool_name=tool,
            tool_input=inputs if inputs is not None else {"command": "forbidden"},
            context=context
            if context is not None
            else {"purpose": "Inspect the project"},
            additionalRules=additional
            if additional is not None
            else {
                "caller_constraint": rule(
                    "tool", check={"intent": "Only inspect the project"}
                ),
            },
        )
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(self.response)
        ) as api:
            return await check(request, self.rules, api)

    async def test_static_rules_win_and_task_rules_are_not_tool_checks(self) -> None:
        self.rules.write_text(
            json.dumps({"same": rule("tool"), "task": rule("task")}), encoding="utf-8"
        )
        project = self.root / ".agents" / "rules"
        project.mkdir(parents=True)
        (project / "same.json").write_text(
            json.dumps(rule("tool", check={"regex": "never-match"})), encoding="utf-8"
        )
        result = await self.inspect()
        self.assertEqual(
            [(item["id"], item["verdict"]) for item in result["results"]],
            [("same", "violation"), ("caller_constraint", "compliant")],
        )
        self.assertEqual(result["errors"], [])
        self.assertFalse((self.root / "cache").exists())

    async def test_identical_retries_never_bypass_rule_violations(self) -> None:
        self.rules.write_text(json.dumps({"deny": rule("tool")}), encoding="utf-8")
        for _ in range(2):
            result = await self.inspect()
            self.assertEqual(result["results"][0]["verdict"], "violation")

    async def test_configured_and_caller_intent_rules_are_batched(self) -> None:
        self.rules.write_text(
            json.dumps(
                {"intent": rule("tool", check={"intent": "Do not modify files"})}
            ),
            encoding="utf-8",
        )
        await self.inspect()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(len(self.calls[0]["questions"]), 2)
        self.assertEqual(self.calls[0]["state"]["purpose"], "Inspect the project")
        self.assertEqual(self.calls[0]["state"]["client"], "codex")
        self.assertEqual(self.calls[0]["state"]["tool_name"], "bash")
        self.assertEqual(
            json.loads(self.calls[0]["state"]["tool_input"]), {"command": "forbidden"}
        )

    async def test_disabled_rules_and_unmatched_triggers_do_not_run(self) -> None:
        self.rules.write_text(
            json.dumps(
                {
                    "disabled": rule("tool", enable={"codex": False}),
                    "other_tool": rule("tool", trigger={"matcher": "^write$"}),
                    "other_field": rule("tool", trigger={"inputFields": ["other"]}),
                }
            ),
            encoding="utf-8",
        )
        result = await self.inspect()
        self.assertEqual(
            [item["id"] for item in result["results"]], ["caller_constraint"]
        )

    async def test_write_and_edit_are_checked_before_modifying_the_file(self) -> None:
        self.rules.write_text(
            json.dumps({"code": rule("code", extensions=[".py"])}), encoding="utf-8"
        )
        source = self.root / "main.py"
        source.write_text("old\n", encoding="utf-8")
        for tool, inputs in [
            ("write", {"path": "main.py", "content": "forbidden"}),
            ("edit", {"path": "main.py", "oldText": "old", "newText": "forbidden"}),
        ]:
            result = await self.inspect(tool, inputs)
            self.assertEqual(result["errors"], [])
            self.assertTrue(
                any(
                    item["id"] == "code" and item["verdict"] == "violation"
                    for item in result["results"]
                )
            )
            self.assertEqual(source.read_text(encoding="utf-8"), "old\n")

    async def test_missing_edit_context_is_not_success(self) -> None:
        result = await self.inspect(
            "edit", {"path": "missing.py", "oldText": "old", "newText": "new"}
        )
        self.assertTrue(result["errors"])

    async def test_jev_failures_unclear_and_invalid_responses_remain_distinct(
        self,
    ) -> None:
        self.verdict = "unclear"
        result = await self.inspect()
        self.assertEqual(result["results"][0]["verdict"], "unclear")
        self.status = 503
        self.assertTrue((await self.inspect())["errors"])
        self.status = 200
        self.verdict = "unexpected"
        self.assertTrue((await self.inspect())["errors"])

    async def test_fingerprint_changes_with_rules_and_project_instructions(
        self,
    ) -> None:
        first = (await self.inspect())["fingerprint"]
        self.rules.write_text(json.dumps({"new": rule("tool")}), encoding="utf-8")
        second = (await self.inspect())["fingerprint"]
        self.assertNotEqual(first, second)
        (self.root / "AGENTS.md").write_text(
            "Do not publish packages.", encoding="utf-8"
        )
        self.assertNotEqual(second, (await self.inspect())["fingerprint"])

    async def test_masked_evidence_cannot_produce_automatic_compliance(self) -> None:
        async def masked(
            *args: object, input_text: str, **kwargs: object
        ) -> tuple[int, str, str]:
            payload = json.loads(input_text)
            payload["state"]["tool_input"] = "[REDACTED]"
            return 0, json.dumps(payload), ""

        with patch("ai_agent_rules.checks.run_process", side_effect=masked):
            result = await self.inspect()
        self.assertTrue(result["errors"])
        self.assertEqual(self.calls, [])

    async def test_client_selects_rules_without_implicit_caller_policy(self) -> None:
        clients: tuple[Literal["codex", "claude", "pi"], ...] = (
            "codex",
            "claude",
            "pi",
        )
        self.rules.write_text(
            json.dumps(
                {
                    client: rule(
                        "tool", enable={name: name == client for name in clients}
                    )
                    for client in clients
                }
            ),
            encoding="utf-8",
        )
        fingerprints = set()
        for client in clients:
            result = await self.inspect(client=client, additional={})
            self.assertEqual([item["id"] for item in result["results"]], [client])
            fingerprints.add(result["fingerprint"])
        self.assertEqual(len(fingerprints), 3)
        self.assertEqual(self.calls, [])

    async def test_context_cannot_override_call_fields(self) -> None:
        for name in ("client", "cwd", "tool_name", "tool_input"):
            with self.assertRaisesRegex(ValueError, "Context must not override"):
                await self.inspect(context={name: "forged"})
        self.assertEqual(self.calls, [])

    async def test_additional_rules_cannot_shadow_static_or_project_rules(self) -> None:
        self.rules.write_text(json.dumps({"static": rule("tool")}), encoding="utf-8")
        project = self.root / ".agents" / "rules"
        project.mkdir(parents=True)
        (project / "project.json").write_text(
            json.dumps(rule("tool")), encoding="utf-8"
        )
        for name in ("static", "project"):
            with self.assertRaisesRegex(ValueError, "must not collide"):
                await self.inspect(
                    additional={name: rule("tool", check={"regex": "never-match"})}
                )
        self.assertEqual(self.calls, [])

    async def test_additional_rules_are_validated_and_change_fingerprint(self) -> None:
        for additional in ({"invalid": {}}, {" ": rule("tool")}):
            with self.assertRaises(ValueError):
                await self.inspect(additional=additional)
        first = await self.inspect(additional={"caller": rule("tool")})
        second = await self.inspect(
            additional={"caller": rule("tool", check={"regex": "other"})}
        )
        self.assertNotEqual(first["fingerprint"], second["fingerprint"])
        self.assertEqual(first["results"][0]["verdict"], "violation")
        self.assertEqual(second["results"][0]["verdict"], "compliant")

    async def test_shared_edit_formats_use_configured_and_additional_code_rules(
        self,
    ) -> None:
        self.rules.write_text(
            json.dumps({"configured": rule("code")}), encoding="utf-8"
        )
        for client, tool, inputs in [
            ("claude", "Write", {"file_path": "main.py", "content": "forbidden"}),
            (
                "codex",
                "functions.apply_patch",
                {
                    "patch": "*** Begin Patch\n*** Add File: main.py\n+forbidden\n*** End Patch"
                },
            ),
        ]:
            result = await self.inspect(
                tool, inputs, client=client, additional={"caller_code": rule("code")}
            )
            self.assertEqual(result["errors"], [])
            self.assertEqual(
                {(item["id"], item["verdict"]) for item in result["results"]},
                {("configured", "violation"), ("caller_code", "violation")},
            )

    async def test_malformed_edit_inputs_are_errors_but_deletions_are_valid(
        self,
    ) -> None:
        for tool in ("write", "Edit", "functions.apply_patch"):
            self.assertTrue((await self.inspect(tool, {}))["errors"])
        source = self.root / "main.py"
        source.write_text("old\n", encoding="utf-8")
        for tool, inputs in [
            ("edit", {"path": "main.py", "oldText": "old", "newText": ""}),
            (
                "apply_patch",
                {"patch": "*** Begin Patch\n*** Delete File: main.py\n*** End Patch"},
            ),
            ("NotebookEdit", {"notebook_path": "main.ipynb", "edit_mode": "delete"}),
        ]:
            self.assertEqual((await self.inspect(tool, inputs))["errors"], [])
        self.assertEqual(source.read_text(encoding="utf-8"), "old\n")


if __name__ == "__main__":
    unittest.main()
