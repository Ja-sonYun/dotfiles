import io
import json
import os
import unittest
from argparse import Namespace
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import mock

import awscli

import aws_ro


class AwsRoTest(unittest.TestCase):
    def setUp(self) -> None:
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        config = self.root / "config"
        config.write_text(
            "[profile reader]\n"
            "region = us-east-1\n"
            "aws_access_key_id = TESTACCESSKEY\n"
            "aws_secret_access_key = test-secret\n"
            "[profile missing-auth]\n"
            "region = us-east-1\n"
            "[profile role]\n"
            "region = us-east-1\n"
            "role_arn = arn:aws:iam::123456789012:role/TestRole\n"
            "source_profile = reader\n"
            "[profile sso]\n"
            "region = us-east-1\n"
            "sso_session = test\n"
            "[sso-session test]\n"
            "sso_start_url = https://example.awsapps.com/start\n"
            "sso_region = us-east-1\n",
            encoding="utf-8",
        )
        self.enterContext(
            mock.patch.dict(
                os.environ,
                {
                    "AWS_DATA_PATH": str(Path(awscli.__file__).with_name("data")),
                    "AWS_CONFIG_FILE": str(config),
                    "AWS_SHARED_CREDENTIALS_FILE": str(self.root / "credentials"),
                    "AWS_EC2_METADATA_DISABLED": "true",
                    "AWS_PAGER": "",
                },
                clear=True,
            )
        )
        self.enterContext(
            mock.patch.object(
                aws_ro,
                "METADATA_PATH",
                Path(__file__).with_name("api_metadata.json"),
            )
        )
        self.enterContext(
            mock.patch(
                "awscli.customizations.assumerole.CACHE_DIR",
                str(self.root / "cli-cache"),
            )
        )
        self.send = self.enterContext(
            mock.patch(
                "botocore.endpoint.Endpoint._send",
                side_effect=AssertionError("Unexpected network request"),
            )
        )

    def run_command(self, arguments: list[str]) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = aws_ro.main(["--no-cli-pager", *arguments])
        return result, stdout.getvalue(), stderr.getvalue()

    def test_lists_profiles_without_authentication(self) -> None:
        result, output, _ = self.run_command(["configure", "list-profiles"])

        self.assertEqual(result, 0)
        self.assertIn("reader", output.splitlines())
        self.assertIn("missing-auth", output.splitlines())
        self.send.assert_not_called()

    def test_environment_does_not_select_a_profile(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "AWS_PROFILE": "reader",
                "AWS_ACCESS_KEY_ID": "ENVACCESSKEY",
                "AWS_SECRET_ACCESS_KEY": "environment-secret",
            },
        ):
            result, _, error = self.run_command(["ec2", "describe-instances"])

        self.assertEqual(result, 2)
        self.assertIn("explicit --profile", error)
        self.send.assert_not_called()

    def test_missing_profile_and_credentials_have_distinct_errors(self) -> None:
        for profile, code, message in (
            ("nonexistent", 2, "does not exist"),
            ("missing-auth", 253, "Authentication is missing"),
        ):
            with self.subTest(profile=profile):
                result, _, error = self.run_command(
                    ["--profile", profile, "ec2", "describe-instances"]
                )
                self.assertEqual(result, code)
                self.assertIn(message, error)
                self.send.assert_not_called()

    def test_read_request_reaches_the_transport_after_classification(self) -> None:
        with mock.patch(
            "botocore.client.BaseClient._make_request",
            return_value=(
                SimpleNamespace(status_code=200, headers={}),
                {"Reservations": []},
            ),
        ) as request:
            result, output, _ = self.run_command(
                ["ec2", "describe-instances", "--profile=reader"]
            )

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output), {"Reservations": []})
        request.assert_called_once()
        self.assertEqual(request.call_args.args[0].name, "DescribeInstances")
        self.send.assert_not_called()

    def test_mutation_is_blocked_before_transport(self) -> None:
        result, _, error = self.run_command(
            [
                "--profile",
                "reader",
                "ec2",
                "terminate-instances",
                "--instance-ids",
                "i-0123456789abcdef0",
            ]
        )

        self.assertEqual(result, 2)
        self.assertIn("Modifying API operation", error)
        self.send.assert_not_called()

    def test_unknown_api_is_blocked(self) -> None:
        policy = aws_ro.ReadOnlyPolicy()
        policy.profile = "reader"
        model = aws_ro.OperationModel(
            {"name": "NewUnclassifiedOperation"},
            service_model=aws_ro.Session().get_service_model("ec2"),
        )

        with self.assertRaisesRegex(aws_ro.ReadOnlyError, "unclassified"):
            policy.before_call(model)
        self.send.assert_not_called()

    def test_credential_apis_are_blocked_even_when_classified_as_read(self) -> None:
        cases = (
            ("datazone", "GetEnvironmentCredentials"),
            ("eks-auth", "AssumeRoleForPodIdentity"),
            ("signin", "CreateOAuth2Token"),
            ("signin", "CreateOAuth2TokenWithIAM"),
            ("finspace-data", "GetProgrammaticAccessCredentials"),
            ("gamelift", "RequestUploadCredentials"),
            ("connect", "GetFederationToken"),
            ("bedrock-agentcore", "GetResourceOauth2Token"),
            ("ssm", "GetAccessToken"),
        )
        session = aws_ro.Session()
        for service, operation in cases:
            with self.subTest(service=service, operation=operation):
                policy = aws_ro.ReadOnlyPolicy()
                policy.profile = "reader"
                policy.metadata = {service: {operation: "read"}}
                model = aws_ro.OperationModel(
                    {"name": operation},
                    service_model=session.get_service_model(service),
                )
                with self.assertRaisesRegex(
                    aws_ro.ReadOnlyError, "Credential issuance"
                ):
                    policy.before_call(model)
        self.send.assert_not_called()

    def test_internal_assume_role_is_separate_from_direct_calls(self) -> None:
        policy = aws_ro.ReadOnlyPolicy()
        session = aws_ro.Session(profile="role")
        session.register("before-call.*.*", policy.before_call)
        policy.initialize(
            session,
            Namespace(profile="role", region="us-east-1", sign_request=True),
        )
        with mock.patch(
            "botocore.client.BaseClient._make_request",
            return_value=(
                SimpleNamespace(status_code=200, headers={}),
                {
                    "Credentials": {
                        "AccessKeyId": "ROLEACCESSKEY",
                        "SecretAccessKey": "role-secret",
                        "SessionToken": "role-token",
                        "Expiration": "2099-01-01T00:00:00Z",
                    }
                },
            ),
        ) as request:
            credentials = session.get_credentials().get_frozen_credentials()
            self.assertEqual(credentials.access_key, "ROLEACCESSKEY")
            request.assert_called_once()
            self.assertEqual(request.call_args.args[0].name, "AssumeRole")

            client = session.create_client("sts", region_name="us-east-1")
            with self.assertRaisesRegex(aws_ro.ReadOnlyError, "Credential issuance"):
                client.assume_role(
                    RoleArn="arn:aws:iam::123456789012:role/TestRole",
                    RoleSessionName="test-session",
                )
            request.assert_called_once()
        self.send.assert_not_called()

    def test_local_settings_do_not_expose_credentials(self) -> None:
        result, output, _ = self.run_command(
            ["--profile", "reader", "configure", "get", "region"]
        )
        self.assertEqual(result, 0)
        self.assertEqual(output.strip(), "us-east-1")

        result, _, error = self.run_command(
            ["--profile", "reader", "configure", "get", "aws_secret_access_key"]
        )
        self.assertEqual(result, 2)
        self.assertIn("Only 'configure get region'", error)
        self.send.assert_not_called()

    def test_upload_and_sync_delete_are_blocked(self) -> None:
        for arguments in (
            ["s3", "cp", "local-file", "s3://example/key"],
            ["s3", "sync", "s3://example/prefix", str(self.root), "--delete"],
        ):
            with self.subTest(arguments=arguments):
                result, _, _ = self.run_command(["--profile", "reader", *arguments])
                self.assertEqual(result, 2)
                self.send.assert_not_called()

    def test_authentication_guidance_does_not_replace_access_denied(self) -> None:
        policy = aws_ro.ReadOnlyPolicy()
        policy.profile = "sso"
        policy.auth_session = aws_ro.Session(profile="sso")
        stderr = io.StringIO()
        result = policy.handle_exception(
            aws_ro.NoCredentialsError(),
            io.StringIO(),
            stderr,
        )
        self.assertEqual(result, 253)
        self.assertIn("aws sso login --profile sso", stderr.getvalue())

        stderr = io.StringIO()
        result = policy.handle_exception(
            aws_ro.ClientError(
                {"Error": {"Code": "AccessDenied", "Message": "Denied"}},
                "DescribeInstances",
            ),
            io.StringIO(),
            stderr,
        )
        self.assertIsNone(result)
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
