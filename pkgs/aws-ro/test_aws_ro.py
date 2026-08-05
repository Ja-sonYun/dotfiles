import importlib.util
import io
import json
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from tempfile import TemporaryDirectory
from types import ModuleType
from unittest import mock


def load_module() -> ModuleType:
    path = Path(__file__).with_name("aws_ro.py")
    spec = importlib.util.spec_from_file_location("aws_ro", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load aws_ro.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AwsRoTest(unittest.TestCase):
    def run_command(
        self,
        arguments: list[str],
        metadata: dict[str, dict[str, dict[str, str]]],
    ) -> tuple[int, str, mock.Mock]:
        module = load_module()
        stderr = io.StringIO()
        execv = mock.Mock()

        with TemporaryDirectory() as directory:
            metadata_path = Path(directory) / "api_metadata.json"
            metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
            with (
                mock.patch.object(module, "AWS_PATH", "/real/aws"),
                mock.patch.object(module, "METADATA_PATH", metadata_path),
                mock.patch.object(module.os, "execv", execv),
                redirect_stderr(stderr),
            ):
                result = module.main(arguments)

        return result, stderr.getvalue(), execv

    def test_allows_read_only_operation(self) -> None:
        result, _, execv = self.run_command(
            ["ec2", "describe-instances", "--region", "us-east-1"],
            {"ec2": {"DescribeInstances": {"type": "ReadOnly"}}},
        )

        self.assertEqual(result, 0)
        execv.assert_called_once_with(
            "/real/aws",
            ["/real/aws", "ec2", "describe-instances", "--region", "us-east-1"],
        )

    def test_allows_global_options_before_operation(self) -> None:
        result, _, execv = self.run_command(
            ["--profile", "prod", "sts", "get-caller-identity"],
            {"sts": {"GetCallerIdentity": {"type": "ReadOnly"}}},
        )

        self.assertEqual(result, 0)
        execv.assert_called_once()

    def test_blocks_mutating_and_unknown_operations(self) -> None:
        metadata = {
            "ec2": {
                "DescribeInstances": {"type": "ReadOnly"},
                "TerminateInstances": {"type": "Mutating"},
            }
        }

        for operation in ("terminate-instances", "new-unknown-operation"):
            with self.subTest(operation=operation):
                result, error, execv = self.run_command(
                    ["ec2", operation],
                    metadata,
                )
                self.assertEqual(result, 2)
                self.assertIn("not classified as read-only", error)
                execv.assert_not_called()

    def test_blocks_credential_operations_even_if_marked_read_only(self) -> None:
        result, _, execv = self.run_command(
            ["sts", "assume-role"],
            {"sts": {"AssumeRole": {"type": "ReadOnly"}}},
        )

        self.assertEqual(result, 2)
        execv.assert_not_called()

    def test_handles_cli_aliases_and_acronyms(self) -> None:
        result, _, execv = self.run_command(
            ["s3api", "get-object-acl", "--bucket", "example", "--key", "file"],
            {"s3": {"GetObjectAcl": {"type": "ReadOnly"}}},
        )

        self.assertEqual(result, 0)
        execv.assert_called_once()

    def test_only_allows_explicit_safe_high_level_command(self) -> None:
        result, _, execv = self.run_command(["s3", "ls"], {})
        self.assertEqual(result, 0)
        execv.assert_called_once()

        result, _, execv = self.run_command(
            ["s3", "cp", "s3://bucket/file", "-"],
            {},
        )
        self.assertEqual(result, 2)
        execv.assert_not_called()

    def test_help_and_version_do_not_require_classification(self) -> None:
        for arguments in (["--version"], ["ec2", "terminate-instances", "help"]):
            with self.subTest(arguments=arguments):
                result, _, execv = self.run_command(arguments, {})
                self.assertEqual(result, 0)
                execv.assert_called_once()


if __name__ == "__main__":
    unittest.main()
