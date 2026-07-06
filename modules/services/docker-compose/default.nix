{
  config,
  lib,
  pkgs,
  cacheDir,
  system ? null,
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
    mkMerge
    mkOption
    optionalAttrs
    splitString
    types
    ;
  cfg = config.services.dockerCompose;

  envValue = value: if builtins.isBool value then lib.boolToString value else toString value;
  hostSystem = if system != null then system else "x86_64-linux";
  isDarwin = lib.hasSuffix "-darwin" hostSystem;
  isLinux = lib.hasSuffix "-linux" hostSystem;
  defaultImageSystem =
    if hostSystem == "aarch64-darwin" then
      "aarch64-linux"
    else if hostSystem == "x86_64-darwin" then
      "x86_64-linux"
    else
      hostSystem;

  projectAttrs = removeAttrs cfg [ "dockerBin" ];
  enabledProjects = filterAttrs (_: project: project.enable) projectAttrs;

  mkShellArrayItems = args: concatMapStrings (arg: "          ${escapeShellArg arg}\n") args;

  mkComposeFile =
    name: project:
    pkgs.writeText "docker-compose-${name}.yaml" (lib.generators.toYAML { } (composeConfig project));

  defaultDockerBin =
    if isDarwin then "${config.homebrew.prefix}/bin/docker" else "${pkgs.docker}/bin/docker";

  dockerBin = if cfg.dockerBin == null then defaultDockerBin else cfg.dockerBin;

  composeConfig =
    project:
    removeAttrs project [
      "enable"
      "options"
      "preStart"
      "images"
      "envFiles"
      "files"
    ];

  enabledImages = project: filterAttrs (_: image: image.enable) project.images;
  enabledEnvFiles = project: filterAttrs (_: envFile: envFile.enable) project.envFiles;
  enabledFiles = project: filterAttrs (_: file: file.enable) project.files;

  imageLoadScript =
    project:
    concatStringsSep "\n" (
      mapAttrsToList (
        _: image:
        let
          imageRef = "${image.imageName}:${image.imageTag}";
        in
        ''
          echo "loading ${imageRef}"
          "$docker" load -i ${escapeShellArg "${image.image}"}
        ''
      ) (enabledImages project)
    );

  mkEnvFileScript =
    _: envFile:
    let
      valueLines = mapAttrsToList (
        key: value: "        printf '%s=%s\\n' ${escapeShellArg key} ${escapeShellArg (envValue value)}"
      ) envFile.environment;
      secretLines = mapAttrsToList (
        key: path: "        printf '%s=%s\\n' ${escapeShellArg key} \"$(cat ${escapeShellArg path})\""
      ) envFile.secrets;
    in
    ''
      mkdir -p "$(dirname ${escapeShellArg envFile.path})"
      {
      ${concatStringsSep "\n" (valueLines ++ secretLines)}
      } > ${escapeShellArg envFile.path}
      chmod ${escapeShellArg envFile.mode} ${escapeShellArg envFile.path}
    '';

  mkFileScript =
    name: file:
    let
      source = pkgs.writeText "docker-compose-${name}" file.text;
      replaceScript = concatStringsSep "\n" (
        mapAttrsToList (placeholder: path: ''
          PLACEHOLDER=${escapeShellArg placeholder} VALUE="$(cat ${escapeShellArg path})" ${pkgs.perl}/bin/perl -0pi -e 's/\Q$ENV{PLACEHOLDER}\E/$ENV{VALUE}/g' ${escapeShellArg file.path}
        '') file.replace
      );
    in
    ''
      mkdir -p "$(dirname ${escapeShellArg file.path})"
      install -m ${escapeShellArg file.mode} ${escapeShellArg "${source}"} ${escapeShellArg file.path}
      ${replaceScript}
    '';

  generatedFileScript =
    project:
    concatStringsSep "\n" (
      (mapAttrsToList mkEnvFileScript (enabledEnvFiles project))
      ++ (mapAttrsToList mkFileScript (enabledFiles project))
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

  isAnonymousVolume =
    volume:
    if builtins.isString volume then
      builtins.length (splitString ":" volume) == 1
    else if builtins.isAttrs volume then
      (volume.type or "volume") == "volume" && (volume.source or "") == ""
    else
      false;

  anonymousVolumeUsage = flatten (
    mapAttrsToList (
      projectName: project:
      flatten (
        mapAttrsToList (
          serviceName: service:
          map (_: "${projectName}.${serviceName}") (filter isAnonymousVolume (service.volumes or [ ]))
        ) (project.services or { })
      )
    ) enabledProjects
  );

  mkRunScript =
    name: project:
    let
      composeFile = mkComposeFile name project;
    in
    pkgs.writeShellScript "docker-compose-${name}" ''
      set -euo pipefail
      export PATH=${escapeShellArg (lib.makeBinPath [ pkgs.coreutils ])}:$PATH

      mkdir -p ${escapeShellArg "${cacheDir}/logs"}

      docker=${escapeShellArg dockerBin}
      compose_file=${escapeShellArg "${composeFile}"}
      name=${escapeShellArg name}

      if [ ! -x "$docker" ]; then
        echo "[dockerCompose] '$docker' not found yet. Install Docker, then re-run system activation. Skipping for now."
        exit 0
      fi

      ${project.preStart}

      ${generatedFileScript project}

      for _ in $(seq 1 60); do
        "$docker" info >/dev/null 2>&1 && break
        sleep 2
      done
      if ! "$docker" info >/dev/null 2>&1; then
        echo "[dockerCompose] docker daemon not reachable. Skipping for now."
        exit 0
      fi

      ${imageLoadScript project}

      up_args=(
      ${mkShellArrayItems project.options.extraFlags}
      )

      exec "$docker" compose -f "$compose_file" -p "$name" up ''${up_args[@]+"''${up_args[@]}"}
    '';
in
{
  options.services.dockerCompose = mkOption {
    default = { };
    description = "Docker Compose projects, each run as a platform-managed service.";
    type = types.submodule {
      freeformType = types.attrsOf (
        types.submodule {
          freeformType = types.attrsOf types.anything;
          options = {
            enable = mkEnableOption "docker compose project";
            preStart = mkOption {
              type = types.lines;
              default = "";
              description = "Shell run before this project starts.";
            };
            options = mkOption {
              default = { };
              type = types.submodule {
                options = {
                  extraFlags = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Extra flags passed to `docker compose up` for this project.";
                  };
                };
              };
            };
            images = mkOption {
              default = { };
              description = "Docker images to load before this project starts.";
              type = types.attrsOf (
                types.submodule (
                  { config, name, ... }:
                  {
                    options = {
                      enable = mkEnableOption "docker image";
                      imageName = mkOption {
                        type = types.str;
                        default = name;
                      };
                      imageTag = mkOption {
                        type = types.str;
                        default = "latest";
                      };
                      system = mkOption {
                        type = types.str;
                        default = defaultImageSystem;
                      };
                      dockerfile = mkOption {
                        type = types.attrs;
                        default = { };
                        description = "Arguments passed to pkgs.dockerTools.buildLayeredImage.";
                      };
                      image = mkOption {
                        type = types.package;
                        default =
                          let
                            imagePkgs = import pkgs.path {
                              inherit (config) system;
                            };
                          in
                          imagePkgs.dockerTools.buildLayeredImage (
                            {
                              name = config.imageName;
                              tag = config.imageTag;
                            }
                            // config.dockerfile
                          );
                      };
                    };
                  }
                )
              );
            };
            envFiles = mkOption {
              default = { };
              description = "Generated Docker Compose env files.";
              type = types.attrsOf (
                types.submodule {
                  options = {
                    enable = mkEnableOption "generated env file";
                    path = mkOption {
                      type = types.str;
                    };
                    mode = mkOption {
                      type = types.str;
                      default = "0600";
                    };
                    environment = mkOption {
                      default = { };
                      type = types.attrsOf (
                        types.oneOf [
                          types.str
                          types.int
                          types.bool
                        ]
                      );
                    };
                    secrets = mkOption {
                      default = { };
                      description = "Environment variables whose values are read from secret files.";
                      type = types.attrsOf types.str;
                    };
                  };
                }
              );
            };
            files = mkOption {
              default = { };
              description = "Generated files for Docker Compose services.";
              type = types.attrsOf (
                types.submodule {
                  options = {
                    enable = mkEnableOption "generated file";
                    path = mkOption {
                      type = types.str;
                    };
                    mode = mkOption {
                      type = types.str;
                      default = "0600";
                    };
                    text = mkOption {
                      type = types.lines;
                    };
                    replace = mkOption {
                      default = { };
                      description = "Placeholder strings replaced with values read from files.";
                      type = types.attrsOf types.str;
                    };
                  };
                }
              );
            };
          };
        }
      );
      options = {
        dockerBin = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Path to the docker binary.";
        };
      };
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = duplicatePorts == [ ];
          message =
            "services.dockerCompose: host port(s) ${concatStringsSep ", " duplicatePorts} "
            + "are published by more than one project. "
            + "(only short \"HOST:CONTAINER\" syntax is checked)";
        }
        {
          assertion = anonymousVolumeUsage == [ ];
          message =
            "services.dockerCompose: anonymous volumes are not allowed in "
            + concatStringsSep ", " (lib.unique anonymousVolumeUsage)
            + ". Use a named volume like \"name:/path\".";
        }
      ];
    }
    (optionalAttrs isDarwin (
      import ./darwin.nix {
        inherit
          cacheDir
          enabledProjects
          lib
          mkRunScript
          ;
      }
    ))
    (optionalAttrs isLinux (
      import ./linux.nix {
        inherit
          enabledProjects
          lib
          mkRunScript
          ;
      }
    ))
  ];
}
