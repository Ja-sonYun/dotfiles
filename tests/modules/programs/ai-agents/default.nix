{
  home-manager,
  nixlib,
  pkgs,
}:
let
  inherit (pkgs) lib;
  testPkgs = (pkgs.extend nixlib.overlays.tool).extend (
    final: prev: {
      mcp-remote = final.writeShellScriptBin "mcp-remote" "exit 0";
      notifycmd = final.writeShellScriptBin "notifycmd" "exit 0";
      pi-extensions = {
        hooks =
          hooks:
          let
            hooksJson = (final.formats.json { }).generate "pi-hooks.json" hooks;
          in
          final.runCommandLocal "pi-ext-hooks-test" { } ''
            mkdir -p $out
            touch $out/index.ts
            cp ${hooksJson} $out/hooks.json
          '';
        mcp-adapter = final.writeTextDir "extension/index.ts" "";
      };
      uv = prev.uv.overrideAttrs (previous: {
        passthru = (previous.passthru or { }) // {
          asPackage = { name, ... }: final.writeShellScriptBin name "exit 0";
        };
      });
    }
  );
  testPackage = name: testPkgs.writeShellScriptBin name "exit 0";
  claudePackage = (testPackage "claude").overrideAttrs (_previous: {
    pname = "claude-code";
    version = "2.1.200";
  });
  aiAgentModules = {
    agents = ../../../../modules/programs/ai-agents/agents;
    enable = ../../../../modules/programs/ai-agents/enable.nix;
    environment = ../../../../modules/programs/ai-agents/environment;
    extensions = ../../../../modules/programs/ai-agents/extensions;
    hooks = ../../../../modules/programs/ai-agents/hooks;
    instructions = ../../../../modules/programs/ai-agents/instructions;
    marketplace = ../../../../modules/programs/ai-agents/marketplace;
    mcp = ../../../../modules/programs/ai-agents/mcp;
    permissions = ../../../../modules/programs/ai-agents/permissions;
    skills = ../../../../modules/programs/ai-agents/skills;
  };
  clientModules = [
    ../../../../modules/programs/claude
    ../../../../modules/programs/claude-desktop
    ../../../../modules/programs/codex
    ../../../../modules/programs/pi
  ];
  baseModule = {
    home = {
      username = "test-user";
      homeDirectory = "/home/test-user";
      stateVersion = "26.05";
    };

    programs = {
      claude-code = {
        enable = true;
        package = claudePackage;
      };
      codex = {
        enable = true;
        package = testPackage "codex";
      };
      pi = {
        enable = true;
        package = testPackage "pi";
      };
    };
  };
  mkConfiguration =
    { featureModules, module }:
    home-manager.lib.homeManagerConfiguration {
      pkgs = testPkgs;
      modules =
        featureModules
        ++ clientModules
        ++ [
          baseModule
          module
        ];
    };
  homeFilesFor =
    configuration:
    import ../../../lib/home-files.nix {
      inherit lib;
      home = configuration.config.home;
      pkgs = testPkgs;
    };
  managedFragment =
    configuration:
    let
      activation = configuration.config.home.activation.codexConfigMerge.data;
      words = lib.splitString " " (builtins.replaceStrings [ "\n" "\\" ] [ " " "" ] activation);
    in
    lib.findFirst (
      word: lib.hasSuffix "-codex-managed-settings.toml" word
    ) (throw "Codex activation does not reference a managed settings fragment") words;
  scenarioArgs = {
    inherit
      aiAgentModules
      homeFilesFor
      managedFragment
      mkConfiguration
      testPkgs
      ;
  };
  scenarios = [
    (import ./core.nix scenarioArgs)
    (import ./hooks.nix scenarioArgs)
    (import ./hook-policy.nix scenarioArgs)
    (import ./marketplace.nix scenarioArgs)
    (import ./mcp.nix scenarioArgs)
    (import ./permissions.nix scenarioArgs)
  ];
  manifest =
    scenario:
    testPkgs.writeText "${lib.strings.sanitizeDerivationName scenario.name}-expected-files.json" (
      builtins.toJSON {
        inherit (scenario) actual expected name;
      }
    );
  manifests = map manifest scenarios;
  hookLibrary = testPkgs.callPackage ../../../../modules/programs/ai-agents/hooks/runtime { };
  testPython = testPkgs.python3.withPackages (python: [
    python.tomlkit
    hookLibrary
  ]);
  codexModule = ../../../../modules/programs/codex;
  codexHookAdapter = ../../../../modules/programs/ai-agents/hooks/adapters/codex_adapter.py;
  hookInput = ../../../../modules/programs/ai-agents/hooks/runtime/hook_input.py;
  statusHook = ../../../../modules/programs/tmux/extensions/agent/status.py;
  notificationHook = ../../../../modules/programs/ai-agents/extensions/notification/notification.py;
  disabledConfiguration = home-manager.lib.homeManagerConfiguration {
    pkgs = testPkgs;
    modules = [
      codexModule
      {
        home = {
          username = "test-user";
          homeDirectory = "/home/test-user";
          stateVersion = "26.05";
        };
      }
    ];
  };
  disabledActivation = disabledConfiguration.config.home.activation.codexConfigMerge.data;
  disabledActivationFile = testPkgs.writeText "disabled-codex-activation" disabledActivation;
  disabledFragment = managedFragment disabledConfiguration;
in
testPkgs.runCommand "ai-tools-tests"
  {
    nativeBuildInputs = [
      testPkgs.nodejs
      testPython
    ];
  }
  ''
    set -euo pipefail

    test_python=${testPython}/bin/python3
    export AI_AGENTS_CODEX_HOOK_ADAPTER=${lib.escapeShellArg (toString codexHookAdapter)}
    export AI_AGENTS_HOOK_INPUT=${lib.escapeShellArg (toString hookInput)}
    export AI_AGENTS_STATUS_HOOK=${lib.escapeShellArg (toString statusHook)}
    export AI_AGENTS_NOTIFICATION_HOOK=${lib.escapeShellArg (toString notificationHook)}

    "$test_python" ${codexModule}/test_merge_config_toml.py
    node --test ${../../../../pkgs/ai-agents/pi/extensions/hooks}/src/index.test.ts
    "$test_python" ${./test_codex_hook_adapter.py}
    "$test_python" ${./test_hook_input.py}
    "$test_python" ${./test_notification_hook.py}
    "$test_python" ${./test_status_hook.py}
    "$test_python" ${../../../lib/check-generated-files.py} \
      ${lib.escapeShellArgs manifests}
    grep -F 'if [[ -f "/home/test-user/.codex/config.toml" ]]; then' ${disabledActivationFile}
    test ! -s ${disabledFragment}

    printf 'PASS: AI agent core, hooks, Marketplace, MCP, permissions, and hook handler tests passed.\n' > "$out"
  ''
