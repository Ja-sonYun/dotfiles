import json
import shlex
import sys
from argparse import Namespace
from pathlib import Path
from typing import TextIO

from awscli.alias import AliasLoader
from awscli.argparser import ArgParseException
from awscli.clidriver import ServiceCommand, ServiceOperation, create_clidriver
from awscli.customizations.assumerole import inject_assume_role_provider_cache
from awscli.customizations.commands import BasicCommand
from awscli.customizations.sso import inject_json_file_cache
from awscli.customizations.waiters import WaitCommand
from botocore.exceptions import (
    ClientError,
    CredentialRetrievalError,
    LoginRefreshPasswordChanged,
    LoginRefreshTokenExpired,
    LoginTokenLoadError,
    NoCredentialsError,
    PartialCredentialsError,
    ProfileNotFound,
    SSOTokenLoadError,
    TokenRetrievalError,
    UnauthorizedSSOTokenError,
)
from botocore.hooks import HierarchicalEmitter
from botocore.model import OperationModel
from botocore.session import Session
from botocore.tokens import SSOTokenProvider, TokenProviderChain

METADATA_PATH = Path("@METADATA_PATH@")
Metadata = dict[str, dict[str, str]]

BLOCKED_OPERATIONS = frozenset(
    {
        ("sts", "AssumeRole"),
        ("sts", "AssumeRoleWithWebIdentity"),
        ("sts", "AssumeRoleWithSAML"),
        ("sts", "GetSessionToken"),
        ("sts", "GetFederationToken"),
        ("sts", "AssumeRoot"),
        ("iam", "CreateAccessKey"),
        ("cognito-identity", "GetCredentialsForIdentity"),
        ("cognito-identity", "GetOpenIdToken"),
        ("cognito-identity", "GetOpenIdTokenForDeveloperIdentity"),
        ("sso", "GetRoleCredentials"),
        ("ecr", "GetAuthorizationToken"),
        ("ecr-public", "GetAuthorizationToken"),
        ("codeartifact", "GetAuthorizationToken"),
        ("redshift", "GetClusterCredentials"),
        ("redshift", "GetClusterCredentialsWithIAM"),
        ("redshift", "GetIdentityCenterAuthToken"),
        ("redshift-serverless", "GetCredentials"),
        ("redshift-serverless", "GetIdentityCenterAuthToken"),
        ("amplifybackend", "GetToken"),
        ("bedrock-agentcore", "GetResourceApiKey"),
        ("bedrock-agentcore", "GetResourceOauth2Token"),
        ("bedrock-agentcore", "GetResourcePaymentToken"),
        ("connect", "GetFederationToken"),
        ("datazone", "GetEnvironmentCredentials"),
        ("eks-auth", "AssumeRoleForPodIdentity"),
        ("finspace-data", "GetProgrammaticAccessCredentials"),
        ("gamelift", "GetComputeAccess"),
        ("gamelift", "GetComputeAuthToken"),
        ("gamelift", "GetInstanceAccess"),
        ("gamelift", "RequestUploadCredentials"),
        ("license-manager", "GetAccessToken"),
        ("route53globalresolver", "GetAccessToken"),
        ("signin", "CreateOAuth2Token"),
        ("signin", "CreateOAuth2TokenWithIAM"),
        ("ssm", "GetAccessToken"),
    }
)
SAFE_CUSTOM_OPERATIONS = frozenset(
    {
        ("configure", "list-profiles"),
        ("configure", "list"),
        ("configure", "get"),
        ("s3", "ls"),
        ("s3", "cp"),
        ("s3", "sync"),
        ("logs", "tail"),
    }
)
AUTHENTICATION_ERRORS = (
    CredentialRetrievalError,
    LoginRefreshTokenExpired,
    LoginRefreshPasswordChanged,
    LoginTokenLoadError,
    NoCredentialsError,
    PartialCredentialsError,
    SSOTokenLoadError,
    TokenRetrievalError,
    UnauthorizedSSOTokenError,
)
AUTHENTICATION_CODES = frozenset(
    {
        "ExpiredToken",
        "ExpiredTokenException",
        "InvalidClientTokenId",
        "InvalidIdentityToken",
        "UnrecognizedClientException",
    }
)


class ReadOnlyError(Exception):
    pass


def load_metadata() -> Metadata:
    try:
        with METADATA_PATH.open(encoding="utf-8") as metadata_file:
            document = json.load(metadata_file)
    except (OSError, json.JSONDecodeError) as error:
        raise ReadOnlyError("API classification data is unavailable.") from error

    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ReadOnlyError("Invalid API classification data.")
    services = document.get("services")
    if not isinstance(services, dict):
        raise ReadOnlyError("Invalid API classification data.")

    metadata: Metadata = {}
    for service, operations in services.items():
        if not isinstance(service, str) or not isinstance(operations, dict):
            raise ReadOnlyError("Invalid API classification data.")
        metadata[service] = {}
        for operation, classification in operations.items():
            if not isinstance(operation, str) or classification not in (
                "read",
                "write",
                "unknown",
            ):
                raise ReadOnlyError("Invalid API classification data.")
            metadata[service][operation] = classification
    return metadata


class ReadOnlyPolicy:
    def __init__(self) -> None:
        self.profile: str | None = None
        self.informational = False
        self.auth_session: Session | None = None
        self.metadata: Metadata | None = None

    def require_profile(self) -> None:
        if not self.profile:
            raise ReadOnlyError(
                "An explicit --profile NAME is required. "
                "Run 'aws-ro configure list-profiles' and ask the user "
                "which profile to use."
            )

    def initialize(
        self,
        session: Session,
        parsed_args: Namespace,
        **kwargs: object,
    ) -> None:
        self.profile = parsed_args.profile
        if not self.informational:
            self.require_profile()
        if not self.profile:
            return
        if self.profile not in session.available_profiles:
            raise ReadOnlyError(
                f"Profile {self.profile!r} does not exist. "
                "Run 'aws-ro configure list-profiles' and ask the user "
                "to provide a profile."
            )
        if not parsed_args.sign_request:
            raise ReadOnlyError(
                "Unsigned requests are not supported; use profile authentication."
            )

        # Keep profile authentication clients separate from guarded service clients.
        auth_session = Session(profile=self.profile)
        if parsed_args.region:
            auth_session.set_config_variable("region", parsed_args.region)
        auth_session.user_agent_name = session.user_agent_name
        auth_session.user_agent_version = session.user_agent_version
        auth_session.user_agent_extra = session.user_agent_extra
        inject_assume_role_provider_cache(auth_session)
        inject_json_file_cache(auth_session)
        resolver = auth_session.get_component("credential_provider")
        for provider in (
            "env",
            "ec2-credentials-file",
            "boto-config",
            "container-role",
            "iam-role",
        ):
            resolver.remove(provider)
        session.register_component("credential_provider", resolver)
        session.register_component(
            "token_provider",
            TokenProviderChain(providers=[SSOTokenProvider(auth_session)]),
        )
        self.auth_session = auth_session

        # CRT transfers bypass Botocore request events; use the guarded classic client.
        profile_config = session.get_scoped_config()
        profile_config["s3"] = {
            **profile_config.get("s3", {}),
            "preferred_transfer_client": "classic",
        }

    def before_call(self, model: OperationModel, **kwargs: object) -> None:
        self.require_profile()
        service = model.service_model.service_name
        operation = model.name
        if (service, operation) in BLOCKED_OPERATIONS:
            raise ReadOnlyError(
                f"Credential issuance or output is blocked: {service}:{operation}."
            )
        if self.metadata is None:
            self.metadata = load_metadata()
        classification = self.metadata.get(service, {}).get(operation, "unknown")
        # Receiving a message changes its visibility and receive count.
        if classification == "write" or (service, operation) == (
            "sqs",
            "ReceiveMessage",
        ):
            raise ReadOnlyError(
                f"Modifying API operation is blocked: {service}:{operation}."
            )
        if classification != "read":
            raise ReadOnlyError(
                f"API operation is unclassified and blocked: {service}:{operation}."
            )

    def command_table(
        self,
        command_table: dict[str, object],
        event_name: str,
        **kwargs: object,
    ) -> None:
        scope = event_name.removeprefix("building-command-table.")
        for name, command in list(command_table.items()):
            if isinstance(command, BasicCommand):
                self.guard_custom_command(command, scope, name)
            elif not isinstance(command, (ServiceCommand, ServiceOperation)):
                del command_table[name]

    def guard_custom_command(
        self,
        command: BasicCommand,
        scope: str,
        name: str,
    ) -> None:
        original = command._run_main

        def run(parsed_args: Namespace, parsed_globals: Namespace) -> int | None:
            if (scope, name) == ("configure", "list-profiles"):
                return original(parsed_args, parsed_globals)
            self.require_profile()
            if (
                not isinstance(command, WaitCommand)
                and (
                    scope,
                    name,
                )
                not in SAFE_CUSTOM_OPERATIONS
            ):
                raise ReadOnlyError(
                    f"Local or custom command is not allowed: {scope} {name}."
                )
            if (scope, name) == ("configure", "get") and (
                parsed_args.varname not in {"region", "output"}
                or parsed_args.sso_session
                or parsed_args.services
            ):
                raise ReadOnlyError(
                    "Only 'configure get region' and "
                    "'configure get output' are allowed."
                )
            if scope == "s3" and name in {"cp", "sync"}:
                source, destination = parsed_args.paths
                if not source.startswith("s3://") or destination.startswith("s3://"):
                    raise ReadOnlyError("Only S3-to-local downloads are allowed.")
                if getattr(parsed_args, "delete", False):
                    raise ReadOnlyError(
                        "Local deletion with 'sync --delete' is blocked."
                    )
                # Resolve authentication before transfer workers handle errors.
                credentials = command._session.get_credentials()
                if credentials is None:
                    raise NoCredentialsError()
                credentials.get_frozen_credentials()
            return original(parsed_args, parsed_globals)

        command._run_main = run

    def login_guidance(self) -> str:
        if self.auth_session is not None:
            profiles = self.auth_session.full_config.get("profiles", {})
            profile = self.profile
            visited: set[str] = set()
            while profile and profile not in visited:
                visited.add(profile)
                config = profiles.get(profile, {})
                quoted_profile = shlex.quote(profile)
                if config.get("sso_session") or config.get("sso_start_url"):
                    return (
                        f"Ask the user to run: aws sso login --profile {quoted_profile}"
                    )
                if config.get("login_session"):
                    return f"Ask the user to run: aws login --profile {quoted_profile}"
                profile = config.get("source_profile")
        return (
            "Ask the user to authenticate the selected profile using its configured "
            "method (aws sso login or aws login when applicable), "
            "then retry with --profile."
        )

    def handle_exception(
        self,
        exception: BaseException,
        stdout: TextIO,
        stderr: TextIO,
        **kwargs: object,
    ) -> int | None:
        if isinstance(exception, ReadOnlyError):
            stderr.write(f"aws-ro: {exception}\n")
            return 2
        if isinstance(exception, ProfileNotFound):
            stderr.write(
                "aws-ro: Profile not found. Run 'aws-ro configure list-profiles' "
                "and ask the user to provide --profile NAME.\n"
            )
            return 2
        authentication_failure = isinstance(exception, AUTHENTICATION_ERRORS)
        if isinstance(exception, ClientError):
            authentication_failure = (
                exception.response.get("Error", {}).get("Code") in AUTHENTICATION_CODES
            )
        if authentication_failure:
            stderr.write(
                "aws-ro: Authentication is missing, invalid, or expired for profile "
                f"{self.profile!r}. {self.login_guidance()}\n"
            )
            return 253
        return None


def main(arguments: list[str]) -> int:
    policy = ReadOnlyPolicy()
    arguments = [
        "help" if argument in {"--help", "-h"} else argument for argument in arguments
    ]
    if not arguments:
        arguments = ["help"]

    driver = create_clidriver(event_hooks=HierarchicalEmitter())
    driver.alias_loader = AliasLoader(alias_filename="")
    events = driver.session.get_component("event_emitter")
    events.unregister("building-command-table", unique_id="cli-alias-injector")
    events.register_first("session-initialized", policy.initialize)
    events.register_first("before-call.*.*", policy.before_call)
    events.register_last("building-command-table", policy.command_table)
    driver._error_handler.inject_handler(0, policy)

    try:
        parser = driver.create_parser(driver._get_command_table())
        parsed, remaining = parser.parse_known_args(arguments)
        if parsed.debug:
            raise ReadOnlyError(
                "--debug is disabled because it can expose authentication data."
            )
        policy.informational = (
            parsed.command == "help"
            or bool(remaining and remaining[-1] == "help")
            or (parsed.command == "configure" and remaining == ["list-profiles"])
        )
        # EntryPoint auto-prompt can create a driver without the policy hooks.
        return driver.main(arguments)
    except SystemExit as error:
        return error.code if isinstance(error.code, int) else 1
    except (ArgParseException, ReadOnlyError, ProfileNotFound) as error:
        return driver._error_handler.handle_exception(error, sys.stdout, sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
