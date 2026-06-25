{
  pkgs,
  lib,
  config,
  configDir,
  agenix-secrets,
  ...
}:
let
  aiBundleSrc = ../../secrets/ai-bundle;
  repoPiDir = "${configDir}/shell/programs/pi";
  repoAiBundleDir = "${configDir}/shell/secrets/ai-bundle";
  outOfStore = config.lib.file.mkOutOfStoreSymlink;

  piExtensions = [
    pkgs.pi-subagents.piExtensionPath
    pkgs.pi-mcp-adapter.piExtensionPath
    pkgs.piolium.piExtensionPath
    pkgs.ponytail.piExtensionPath
  ];

  extensionArgs = lib.concatMapStringsSep " \\\n    " (
    extension: "-e ${lib.escapeShellArg extension}"
  ) piExtensions;

  extensionEntries = lib.filterAttrs (
    name: type:
    (type == "regular" && (lib.hasSuffix ".ts" name || lib.hasSuffix ".json" name))
    || type == "directory"
  ) (builtins.readDir ./extensions);

  devExtensionEntries = lib.filterAttrs (_name: type: type == "directory") (
    builtins.readDir ./dev-extensions
  );

  extensionHomeFiles = lib.mapAttrs' (
    name: _type:
    lib.nameValuePair ".pi/agent-dev/extensions/${name}" {
      force = true;
      source = outOfStore "${repoPiDir}/extensions/${name}";
    }
  ) extensionEntries;

  devExtensionHomeFiles = lib.mapAttrs' (
    name: _type:
    lib.nameValuePair ".pi/agent-dev/extensions/${name}" {
      force = true;
      source = outOfStore "${repoPiDir}/dev-extensions/${name}";
    }
  ) devExtensionEntries;

  skillDirNamesFrom =
    root:
    builtins.attrNames (
      lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (root + "/${name}/SKILL.md")
      ) (builtins.readDir root)
    );

  localSkillSources = map (name: {
    inherit name;
    source = "${repoAiBundleDir}/skills/${name}";
    outOfStore = true;
  }) (skillDirNamesFrom (aiBundleSrc + "/skills"));

  vendorEntries = lib.filterAttrs (_name: type: type == "directory") (
    builtins.readDir (aiBundleSrc + "/vendors")
  );

  vendorSkillSources = lib.concatMap (
    vendorName:
    let
      vendorSrc = aiBundleSrc + "/vendors/${vendorName}";
      hasSkillsDir = builtins.pathExists (vendorSrc + "/skills");
      scanRoot = if hasSkillsDir then vendorSrc + "/skills" else vendorSrc;
      sourceRoot = "${repoAiBundleDir}/vendors/${vendorName}" + lib.optionalString hasSkillsDir "/skills";
    in
    map (name: {
      inherit name;
      source = "${sourceRoot}/${name}";
      outOfStore = true;
    }) (skillDirNamesFrom scanRoot)
  ) (builtins.attrNames vendorEntries);

  ponytailSkillSources = map (name: {
    inherit name;
    source = pkgs.ponytail.skillsPath + "/${name}";
    outOfStore = false;
  }) (skillDirNamesFrom pkgs.ponytail.skillsPath);

  skillSources = localSkillSources ++ vendorSkillSources ++ ponytailSkillSources;
  skillNames = map (skill: skill.name) skillSources;
  duplicateSkillNames = lib.unique (
    lib.filter (name: lib.length (lib.filter (candidate: candidate == name) skillNames) > 1) skillNames
  );

  skillHomeFiles =
    assert lib.assertMsg (
      duplicateSkillNames == [ ]
    ) "Duplicate Pi dev skill names: ${lib.concatStringsSep ", " duplicateSkillNames}";
    builtins.listToAttrs (
      map (skill: {
        name = ".pi/agent-dev/skills/${skill.name}";
        value = {
          force = true;
          source = if skill.outOfStore then outOfStore skill.source else skill.source;
        };
      }) skillSources
    );

  piDev = pkgs.writeShellScriptBin "pi-dev" ''
    case "''${1-}" in
      install|remove|uninstall|update)
        printf '%s\n' "pi ''${1} is disabled in this Nix-managed wrapper. Manage Pi packages through dotfiles/Nix instead." >&2
        exit 64
      ;;
    esac

    export NODE_OPTIONS="--no-warnings=ExperimentalWarning''${NODE_OPTIONS:+ ''${NODE_OPTIONS}}"
    export PI_SKIP_VERSION_CHECK=1
    export PI_CODING_AGENT_DIR="${config.home.homeDirectory}/.pi/agent-dev"
    export PI_CODING_AGENT_SESSION_DIR="${config.home.homeDirectory}/.pi/agent/sessions"

    exec ${pkgs.pi}/bin/pi \
    ${extensionArgs} \
      "$@"
  '';
in
{
  home.packages = [
    piDev
  ];

  home.file =
    extensionHomeFiles
    // devExtensionHomeFiles
    // skillHomeFiles
    // {
      ".pi/agent-dev/AGENTS.md" = {
        force = true;
        source = outOfStore "${repoAiBundleDir}/AGENTS.md";
      };

      ".pi/agent-dev/agents" = {
        force = true;
        source = outOfStore "${repoAiBundleDir}/agents";
      };

      ".pi/agent-dev/settings.json" = {
        force = true;
        source = outOfStore "${repoPiDir}/dev-profile/settings.json";
      };

      ".pi/agent-dev/keybindings.json" = {
        force = true;
        source = outOfStore "${repoPiDir}/dev-profile/keybindings.json";
      };
    };
}
