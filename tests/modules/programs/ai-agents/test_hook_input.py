import os
import runpy
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import cast

HookInput = dict[str, object]
LoadHookInput = Callable[[str], HookInput]
HookPredicate = Callable[[HookInput], bool]

hooks_dir = os.environ.get("AI_AGENTS_HOOKS_DIR")
HOOKS_DIR = (
    Path(hooks_dir)
    if hooks_dir
    else (
        Path(__file__).parents[4]
        / "shell"
        / "secrets"
        / "modules"
        / "home-manager"
        / "ai-agents"
        / "hooks"
    )
)
HOOK_INPUT_PATH = HOOKS_DIR / "hook_input.py"
HOOK_INPUT = runpy.run_path(str(HOOK_INPUT_PATH))
LOAD_HOOK_INPUT = cast(LoadHookInput, HOOK_INPUT["load_hook_input"])
IS_PROPOSED_PLAN = cast(HookPredicate, HOOK_INPUT["is_proposed_plan"])


class LoadHookInputTest(unittest.TestCase):
    def test_loads_object(self) -> None:
        self.assertEqual(
            LOAD_HOOK_INPUT('{"hook_event_name":"Stop"}'),
            {"hook_event_name": "Stop"},
        )

    def test_malformed_and_non_object_input_become_empty_object(self) -> None:
        for payload in ("{", "[]", '"text"', ""):
            with self.subTest(payload=payload):
                self.assertEqual(LOAD_HOOK_INPUT(payload), {})


class HookPredicateTest(unittest.TestCase):
    def test_proposed_plan_is_case_insensitive(self) -> None:
        for tag in ("<proposed_plan>", "<PROPOSED_PLAN>", "<PrOpOsEd_PlAn>"):
            with self.subTest(tag=tag):
                self.assertTrue(
                    IS_PROPOSED_PLAN({"last_assistant_message": f"{tag}continue"})
                )
        self.assertFalse(IS_PROPOSED_PLAN({"last_assistant_message": "Done."}))


if __name__ == "__main__":
    unittest.main()
