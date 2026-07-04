{
  config,
  lib,
  pkgs,
  cacheDir,
  ...
}:

let
  inherit (lib)
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filter
    filterAttrs
    flatten
    mapAttrsToList
    mkEnableOption
    mkOption
    nameValuePair
    splitString
    types
    ;
  cfg = config.services.dockerCompose;

  yamlFormat = pkgs.formats.yaml { };

  projectAttrs = removeAttrs cfg [
    "preStart"
    "dockerBin"
  ];

  enabledProjects = filterAttrs (_: project: project.enable) projectAttrs;

  managedLabelKey = "com.docker.compose.project";

  mkShellArrayItems = args: concatMapStrings (arg: "          ${escapeShellArg arg}\n") args;

  mkComposeFile =
    name: project:
    yamlFormat.generate "docker-compose-${name}.yaml" (
      removeAttrs project [
        "enable"
        "options"
      ]
    );

  hostPortOf =
    spec:
    if !builtins.isString spec then
      null
    else
      let
        parts = splitString ":" spec;
        len = builtins.length parts;
      in
      if len >= 2 then builtins.elemAt parts (len - 2) else null;

  projectHostPorts =
    project:
    let
      services = project.services or { };
      ports = flatten (mapAttrsToList (_: svc: svc.ports or [ ]) services);
    in
    filter (p: p != null) (map hostPortOf ports);

  portUsage = flatten (
    mapAttrsToList (
      name: project: map (port: { inherit name port; }) (projectHostPorts project)
    ) enabledProjects
  );

  duplicatePorts = filter (port: builtins.length (filter (u: u.port == port) portUsage) > 1) (
    lib.unique (map (u: u.port) portUsage)
  );

  mkAgent =
    name: project:
    let
      composeFile = mkComposeFile name project;
    in
    nameValuePair "dockerCompose-${name}" {
      serviceConfig = {
        Label = "com.server.docker-compose.${name}";
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        StandardOutPath = "${cacheDir}/logs/docker-compose-${name}.out.log";
        StandardErrorPath = "${cacheDir}/logs/docker-compose-${name}.err.log";
      };

      script = ''
        #!/usr/bin/env bash
        set -euo pipefail

        mkdir -p ${escapeShellArg "${cacheDir}/logs"}

        docker=${escapeShellArg cfg.dockerBin}
        compose_file=${escapeShellArg "${composeFile}"}
        name=${escapeShellArg name}

        if [ ! -x "$docker" ]; then
          echo "[dockerCompose] '$docker' not found yet. Install Docker, then re-run 'darwin-rebuild switch' (or 'make deploy'). Skipping for now."
          exit 0
        fi

        ${cfg.preStart}

        for _ in $(seq 1 60); do
          "$docker" info >/dev/null 2>&1 && break
          sleep 2
        done
        if ! "$docker" info >/dev/null 2>&1; then
          echo "[dockerCompose] docker daemon not reachable. Skipping for now."
          exit 0
        fi

        up_args=(
        ${mkShellArrayItems project.options.extraFlags}
        )

        exec "$docker" compose -f "$compose_file" -p "$name" up ''${up_args[@]+"''${up_args[@]}"}
      '';
    };

  mkReaper = nameValuePair "dockerComposeReaper" {
    serviceConfig = {
      Label = "com.server.docker-compose-reaper";
      RunAtLoad = true;
      KeepAlive = false;
      ProcessType = "Background";
      StandardOutPath = "${cacheDir}/logs/docker-compose-reaper.out.log";
      StandardErrorPath = "${cacheDir}/logs/docker-compose-reaper.err.log";
    };

    script = ''
      #!/usr/bin/env bash
      set -euo pipefail

      mkdir -p ${escapeShellArg "${cacheDir}/logs"}

      docker=${escapeShellArg cfg.dockerBin}

      [ -x "$docker" ] || exit 0
      "$docker" info >/dev/null 2>&1 || exit 0

      keep=(
      ${mkShellArrayItems (mapAttrsToList (name: _: name) enabledProjects)}
      )
      in_keep() { local x; for x in ''${keep[@]+"''${keep[@]}"}; do [ "$x" = "$1" ] && return 0; done; return 1; }

      "$docker" ps -a --filter ${escapeShellArg "label=${managedLabelKey}"} \
        --format ${escapeShellArg "{{ index .Labels \"${managedLabelKey}\" }}"} \
        | sort -u \
        | while read -r proj; do
            [ -n "$proj" ] || continue
            in_keep "$proj" || "$docker" compose -p "$proj" down -v >/dev/null 2>&1 || true
          done || true
    '';
  };
in
{
  options.services.dockerCompose = mkOption {
    default = { };
    description = "Docker Compose projects, each run as a launchd-managed agent.";
    type = types.submodule {
      freeformType = types.attrsOf (
        types.submodule {
          freeformType = yamlFormat.type;
          options = {
            enable = mkEnableOption "docker compose project";
            options = mkOption {
              default = { };
              type = types.submodule {
                options.extraFlags = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Extra flags passed to `docker compose up` for this project.";
                };
              };
            };
          };
        }
      );
      options.preStart = mkOption {
        type = types.lines;
        default = "";
        description = "Shell run before each project starts, e.g. \"open -ga OrbStack\" to ensure the engine is up.";
      };
      options.dockerBin = mkOption {
        type = types.str;
        default = "${config.homebrew.prefix}/bin/docker";
        description = "Path to the docker binary.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = duplicatePorts == [ ];
        message =
          "services.dockerCompose: host port(s) ${concatStringsSep ", " duplicatePorts} "
          + "are published by more than one project. "
          + "(only short \"HOST:CONTAINER\" syntax is checked)";
      }
    ];

    launchd.user.agents = builtins.listToAttrs ([ mkReaper ] ++ mapAttrsToList mkAgent enabledProjects);
  };
}
