import hashlib
import json
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

import tomlkit


class _MergeConfigTest(unittest.TestCase):
    def _run(
        self,
        target: Path,
        fragment: Path,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("merge-config-toml.py")),
                str(target),
                str(fragment),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def _write_fragment(self, path: Path, value: dict[str, Any]) -> None:
        path.write_text(tomlkit.dumps(value))

    def test_preserves_user_values_and_removes_generated_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "config.toml"
            fragment = root / "fragment.toml"
            secret = root / "provider-url"

            target.write_text(
                'model = "app"\n'
                'default_permissions = "user"\n'
                "# keep\n"
                "[features]\nuser_only = true\n"
                "[tui]\nuser_only = true\n"
                "[permissions.user]\nextends = \":read-only\"\n"
                "[permissions.managed]\nuser_only = true\n"
                "[mcp_servers.user]\nurl = \"https://user.test\"\n"
                "[mcp_servers.shared]\nuser_only = true\n"
                "[model_providers.shared]\nuser_only = true\n"
                "[[hooks.UserPromptSubmit]]\nmatcher = \"user\"\n"
                "[[hooks.UserPromptSubmit.hooks]]\n"
                'type = "command"\ncommand = "user"\n'
            )
            secret.write_text('https://nix.test/"quoted"\n')
            managed = {
                "default_permissions": "managed",
                "features": {"memories": True},
                "mcp_servers": {
                    "nix": {"url": "https://nix.test"},
                    "shared": {"url": "https://shared.test"},
                },
                "model_providers": {
                    "shared": {
                        "name": "Nix",
                        "base_url": {"_secret": str(secret)},
                    }
                },
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "x",
                            "hooks": [{"type": "command", "command": "true"}],
                        }
                    ],
                },
                "permissions": {"managed": {"extends": ":workspace"}},
                "tui": {
                    "show_tooltips": False,
                    "keymap": {"pager": {"half_page_up": "ctrl-u"}},
                },
            }
            self._write_fragment(fragment, managed)

            result = self._run(target, fragment)

            self.assertEqual(result.returncode, 0, result.stderr)
            output = target.read_text()
            config = tomlkit.parse(output)
            self.assertIn("# keep", output)
            self.assertEqual(config["model"], "app")
            self.assertEqual(config["default_permissions"], "managed")
            self.assertEqual(config["features"], {"user_only": True, "memories": True})
            self.assertTrue(config["tui"]["user_only"])
            self.assertFalse(config["tui"]["show_tooltips"])
            self.assertEqual(
                config["tui"]["keymap"]["pager"]["half_page_up"],
                "ctrl-u",
            )
            self.assertEqual(config["permissions"]["user"]["extends"], ":read-only")
            self.assertTrue(config["permissions"]["managed"]["user_only"])
            self.assertEqual(
                config["permissions"]["managed"]["extends"],
                ":workspace",
            )
            self.assertEqual(
                set(config["mcp_servers"]),
                {"user", "shared", "nix"},
            )
            self.assertTrue(config["mcp_servers"]["shared"]["user_only"])
            self.assertEqual(
                config["mcp_servers"]["shared"]["url"],
                "https://shared.test",
            )
            self.assertTrue(config["model_providers"]["shared"]["user_only"])
            self.assertEqual(
                config["model_providers"]["shared"]["base_url"],
                'https://nix.test/"quoted"',
            )
            self.assertEqual(
                set(config["hooks"]),
                {"UserPromptSubmit", "PreToolUse", "state"},
            )
            hook_state_key = f"{target}:pre_tool_use:0:0"
            trusted_input = {
                "event_name": "pre_tool_use",
                "hooks": [
                    {
                        "type": "command",
                        "command": "true",
                        "timeout": 600,
                        "async": False,
                    }
                ],
                "matcher": "x",
            }
            trusted_hash = hashlib.sha256(
                json.dumps(
                    trusted_input,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode()
            ).hexdigest()
            self.assertEqual(
                config["hooks"]["state"][hook_state_key]["trusted_hash"],
                f"sha256:{trusted_hash}",
            )
            self.assertEqual(
                config["features"].item("memories").trivia.comment,
                "# nix-generated",
            )
            self.assertEqual(
                config["features"].item("user_only").trivia.comment,
                "",
            )
            self.assertEqual(
                config["mcp_servers"]["nix"].trivia.comment,
                "# nix-generated-container",
            )
            self.assertTrue(
                all(
                    table.trivia.comment == "# nix-generated"
                    for table in config["hooks"]["PreToolUse"]
                )
            )
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            before = target.read_text()

            result = self._run(target, fragment)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_text(), before)

            self._write_fragment(
                fragment,
                {
                    "default_permissions": "managed",
                    "mcp_servers": {
                        "shared": {"url": "https://updated.test"},
                    },
                    "permissions": {"managed": {"extends": ":read-only"}},
                },
            )
            result = self._run(target, fragment)

            self.assertEqual(result.returncode, 0, result.stderr)
            config = tomlkit.parse(target.read_text())
            self.assertEqual(config["features"], {"user_only": True})
            self.assertEqual(config["tui"], {"user_only": True})
            self.assertEqual(set(config["mcp_servers"]), {"user", "shared"})
            self.assertTrue(config["mcp_servers"]["shared"]["user_only"])
            self.assertEqual(
                config["mcp_servers"]["shared"]["url"],
                "https://updated.test",
            )
            self.assertEqual(config["model_providers"]["shared"], {"user_only": True})
            self.assertEqual(set(config["hooks"]), {"UserPromptSubmit"})
            self.assertTrue(config["permissions"]["managed"]["user_only"])
            self.assertEqual(
                config["permissions"]["managed"]["extends"],
                ":read-only",
            )

            self._write_fragment(fragment, {})
            result = self._run(target, fragment)

            self.assertEqual(result.returncode, 0, result.stderr)
            output = target.read_text()
            config = tomlkit.parse(output)
            self.assertNotIn("default_permissions", config)
            self.assertEqual(config["features"], {"user_only": True})
            self.assertEqual(config["tui"], {"user_only": True})
            self.assertEqual(set(config["mcp_servers"]), {"user", "shared"})
            self.assertEqual(config["mcp_servers"]["shared"], {"user_only": True})
            self.assertEqual(config["model_providers"]["shared"], {"user_only": True})
            self.assertEqual(set(config["hooks"]), {"UserPromptSubmit"})
            self.assertEqual(config["permissions"]["managed"], {"user_only": True})
            self.assertNotIn("# nix-generated", output)

    def test_preserves_values_in_generated_container(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "config.toml"
            fragment = root / "fragment.toml"
            self._write_fragment(fragment, {"features": {"nix": True}})
            result = self._run(target, fragment)
            self.assertEqual(result.returncode, 0, result.stderr)

            config = tomlkit.parse(target.read_text())
            config["features"]["user"] = True
            target.write_text(tomlkit.dumps(config))
            self._write_fragment(fragment, {})

            result = self._run(target, fragment)

            self.assertEqual(result.returncode, 0, result.stderr)
            output = target.read_text()
            config = tomlkit.parse(output)
            self.assertEqual(config["features"], {"user": True})
            self.assertNotIn("# nix-generated", output)

    def test_empty_fragment_leaves_unmanaged_config_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "config.toml"
            fragment = root / "fragment.toml"
            original = '# keep\nmodel="app"\n'
            target.write_text(original)
            target.chmod(0o644)
            self._write_fragment(fragment, {})

            result = self._run(target, fragment)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_text(), original)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)

    def test_failures_do_not_modify_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "config.toml"
            fragment = root / "fragment.toml"
            target.write_text(
                'model = "app"\n'
                "[features] # nix-generated\nmemories = true\n"
            )
            self._write_fragment(
                fragment,
                {
                    "model_providers": {
                        "missing": {
                            "base_url": {"_secret": str(root / "missing")}
                        }
                    }
                },
            )
            before = target.read_text()

            result = self._run(target, fragment)

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), before)

            target.write_text("invalid = [")
            before = target.read_text()
            self._write_fragment(fragment, {"features": {"memories": True}})

            result = self._run(target, fragment)

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), before)


if __name__ == "__main__":
    unittest.main()
