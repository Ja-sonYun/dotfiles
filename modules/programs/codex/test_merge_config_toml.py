import hashlib
import json
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import tomlkit


class _MergeConfigTest(unittest.TestCase):
    def _run(
        self,
        target: Path,
        fragment: Path,
        *state_paths: Path,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("merge-config-toml.py")),
                str(target),
                str(fragment),
                *map(str, state_paths),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_merge_delete_and_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "config.toml"
            fragment = root / "fragment.toml"
            mcp_state = root / "mcp.json"
            provider_state = root / "provider.json"
            state_paths = (mcp_state, provider_state)
            secret = root / "provider-url"

            target.write_text(
                'model = "app"\n'
                'default_permissions = "user"\n'
                "# keep\n"
                "[mcp_servers.user]\nurl = \"https://user.test\"\n"
                "[mcp_servers.old]\nurl = \"https://old.test\"\n"
                "[model_providers.user]\nname = \"User\"\n"
                "[model_providers.old]\nname = \"Old\"\n"
                "[hooks.old]\nenabled = true\n"
                "[permissions.user]\nextends = \":read-only\"\n"
                "[permissions.managed]\nextends = \":read-only\"\n"
                "[features]\nold = true\n"
                "[tui]\nshow_tooltips = true\n"
            )
            mcp_state.write_text('["old"]')
            provider_state.write_text('["old"]')
            secret.write_text('https://nix.test/"quoted"\n')

            managed = {
                "default_permissions": "managed",
                "features": {"memories": True},
                "mcp_servers": {"nix": {"url": "https://nix.test"}},
                "model_providers": {
                    "nix": {
                        "name": "Nix",
                        "base_url": {"_secret": str(secret)},
                    }
                },
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "x",
                            "hooks": [{"type": "command", "command": "true"}],
                        },
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "second",
                                    "timeout": 5,
                                    "async": True,
                                }
                            ]
                        },
                    ],
                },
                "permissions": {"managed": {"extends": ":workspace"}},
                "tui": {
                    "show_tooltips": False,
                    "keymap": {"pager": {"half_page_up": "ctrl-u"}},
                },
            }
            fragment.write_text(tomlkit.dumps(managed))

            result = self._run(target, fragment, *state_paths)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = target.read_text()
            config = tomlkit.parse(output)
            self.assertIn("# keep", output)
            self.assertEqual(config["model"], "app")
            self.assertEqual(set(config["mcp_servers"]), {"user", "nix"})
            self.assertEqual(set(config["model_providers"]), {"user", "nix"})
            self.assertEqual(
                config["model_providers"]["nix"]["base_url"],
                'https://nix.test/"quoted"',
            )
            self.assertNotIn("old", config["hooks"])
            self.assertEqual(config["features"], {"memories": True})
            self.assertFalse(config["tui"]["show_tooltips"])
            self.assertEqual(config["permissions"]["user"]["extends"], ":read-only")
            self.assertEqual(config["permissions"]["managed"]["extends"], ":workspace")
            self.assertEqual(config["default_permissions"], "managed")
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
                config["hooks"]["state"][hook_state_key],
                {
                    "enabled": True,
                    "trusted_hash": f"sha256:{trusted_hash}",
                },
            )
            second_hook_state_key = f"{target}:pre_tool_use:1:0"
            second_trusted_input = {
                "event_name": "pre_tool_use",
                "hooks": [
                    {
                        "type": "command",
                        "command": "second",
                        "timeout": 5,
                        "async": True,
                    }
                ],
            }
            second_trusted_hash = hashlib.sha256(
                json.dumps(
                    second_trusted_input,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode()
            ).hexdigest()
            self.assertEqual(
                config["hooks"]["state"][second_hook_state_key],
                {
                    "enabled": True,
                    "trusted_hash": f"sha256:{second_trusted_hash}",
                },
            )
            self.assertEqual(
                set(config["hooks"]["state"]),
                {hook_state_key, second_hook_state_key},
            )
            self.assertIn(
                'default_permissions = "managed" # nix-generated', output
            )
            self.assertIn("[mcp_servers.nix] # nix-generated", output)
            self.assertIn("[model_providers.nix] # nix-generated", output)
            self.assertIn(
                f'[hooks.state."{hook_state_key}"] # nix-generated',
                output,
            )
            self.assertIn("[[hooks.PreToolUse]] # nix-generated", output)
            self.assertIn("[[hooks.PreToolUse.hooks]] # nix-generated", output)
            self.assertIn("[permissions.managed] # nix-generated", output)
            self.assertIn("[features] # nix-generated", output)
            self.assertIn("[tui] # nix-generated", output)
            self.assertIn("[tui.keymap.pager] # nix-generated", output)
            self.assertNotIn("[mcp_servers.user] # nix-generated", output)
            self.assertEqual(json.loads(mcp_state.read_text()), ["nix"])
            self.assertEqual(json.loads(provider_state.read_text()), ["nix"])
            for path in (target, *state_paths):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

            fragment.write_text(
                tomlkit.dumps(
                    {
                        "hooks": managed["hooks"],
                        "permissions": managed["permissions"],
                        "default_permissions": "managed",
                    }
                )
            )
            result = self._run(target, fragment, *state_paths)
            self.assertEqual(result.returncode, 0, result.stderr)
            config = tomlkit.parse(target.read_text())
            self.assertEqual(set(config["mcp_servers"]), {"user"})
            self.assertEqual(set(config["model_providers"]), {"user"})
            self.assertNotIn("features", config)
            self.assertNotIn("tui", config)
            self.assertNotIn("[mcp_servers.nix]", target.read_text())
            self.assertEqual(target.read_text().count("# nix-generated"), 8)

            fragment.write_text(
                tomlkit.dumps(
                    {
                        "model_providers": {
                            "missing": {
                                "base_url": {"_secret": str(root / "missing")}
                            }
                        }
                    }
                )
            )
            before = (
                target.read_text(),
                mcp_state.read_text(),
                provider_state.read_text(),
            )
            result = self._run(target, fragment, *state_paths)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(
                (
                    target.read_text(),
                    mcp_state.read_text(),
                    provider_state.read_text(),
                ),
                before,
            )

            target.write_text("invalid = [")
            before = target.read_text()
            result = self._run(target, fragment, *state_paths)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), before)


if __name__ == "__main__":
    unittest.main()
