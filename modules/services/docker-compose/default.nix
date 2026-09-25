{
  config,
  lib,
  paths,
  pkgs,
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
  cacheDir = paths.cache;

  shellValue =
    value:
    if pkgs.tool.secretValue.isSecret value then
      ''"$(read_secret_file ${escapeShellArg value._secret})"''
    else
      escapeShellArg (if builtins.isBool value then lib.boolToString value else toString value);

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

  projectAttrs = removeAttrs cfg [
    "dockerBin"
    "extraPath"
  ];
  enabledProjects = filterAttrs (_: project: project.enable) projectAttrs;

  mkShellArrayItems = args: concatMapStrings (arg: "          ${escapeShellArg arg}\n") args;

  mkComposeFile =
    name: project:
    pkgs.writeText "docker-compose-${name}.yaml" (lib.generators.toYAML { } (composeConfig project));

  defaultDockerBin = "${pkgs.docker}/bin/docker";

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

  mkFileWriteScript = file: contents: ''
    (
      umask 077
      mkdir -p "$(dirname ${escapeShellArg file.path})"
      file_tmp="$(mktemp ${escapeShellArg "${file.path}.XXXXXX"})"
      trap 'rm -f "$file_tmp"' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      ${contents}
      chmod ${escapeShellArg file.mode} "$file_tmp"
      mv -f "$file_tmp" ${escapeShellArg file.path}
    )
  '';

  mkEnvFileScript =
    _: envFile:
    let
      valueLines = mapAttrsToList (key: value: ''
        value=${shellValue value}
        write_env_value ${escapeShellArg key} "$value"
      '') envFile.environment;
    in
    mkFileWriteScript envFile ''
      write_env_value() {
        local value="$2"
        value="''${value//\\/\\\\}"
        value="''${value//\"/\\\"}"
        value="''${value//\$/\$\$}"
        value="''${value//$'\n'/\\n}"
        value="''${value//$'\r'/\\r}"
        value="''${value//$'\t'/\\t}"
        printf '%s="%s"\n' "$1" "$value"
      }

      {
        :
      ${concatStringsSep "\n" valueLines}
      } > "$file_tmp"
    '';

  mkFileScript =
    name: file:
    let
      source = pkgs.writeText "docker-compose-${name}" file.text;
      replaceScript = concatStringsSep "\n" (
        mapAttrsToList (placeholder: value: ''
          value=${shellValue value}
          PLACEHOLDER=${escapeShellArg placeholder} VALUE="$value" ${pkgs.perl}/bin/perl -0pi -e 's/\Q$ENV{PLACEHOLDER}\E/$ENV{VALUE}/g' "$file_tmp"
        '') file.replace
      );
    in
    mkFileWriteScript file ''
      cat ${escapeShellArg "${source}"} > "$file_tmp"
      ${replaceScript}
    '';

  generatedFileScript =
    project:
    concatStringsSep "\n" (
      (mapAttrsToList mkEnvFileScript (enabledEnvFiles project))
      ++ (mapAttrsToList mkFileScript (enabledFiles project))
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
      export PATH="$(dirname "$docker")":${escapeShellArg (concatStringsSep ":" cfg.extraPath)}${
        lib.optionalString (cfg.extraPath != [ ]) ":"
      }"$PATH"

      read_secret_file() {
        for _ in $(seq 1 60); do
          [ -r "$1" ] && cat "$1" && return 0
          sleep 1
        done
        echo "[dockerCompose] secret file '$1' not readable" >&2
        return 1
      }

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
    description = "Docker Compose projects.";
    type = types.submodule {
      freeformType = types.attrsOf (
        types.submodule {
          freeformType = types.attrsOf types.anything;
          options = {
            enable = mkEnableOption "docker compose project";
            preStart = mkOption {
              type = types.lines;
              default = "";
              description = "Pre-start shell script.";
            };
            options = mkOption {
              default = { };
              type = types.submodule {
                options = {
                  extraFlags = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Extra docker compose up flags.";
                  };
                };
              };
            };
            images = mkOption {
              default = { };
              description = "Images to load before startup.";
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
                        description = "buildLayeredImage arguments.";
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
                      description = "Environment values; supports { _secret = path; }.";
                      type = types.attrsOf (
                        types.oneOf [
                          types.str
                          types.int
                          types.bool
                          pkgs.tool.secretValue.type
                        ]
                      );
                    };
                  };
                }
              );
            };
            files = mkOption {
              default = { };
              description = "Generated service files.";
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
                      description = "Placeholder values; supports { _secret = path; }.";
                      type = types.attrsOf (
                        types.oneOf [
                          types.str
                          pkgs.tool.secretValue.type
                        ]
                      );
                    };
                  };
                }
              );
            };
          };
        }
      );
      options = {
        extraPath = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional service PATH directories.";
        };
        dockerBin = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Docker executable path.";
        };
      };
    };
  };

  config = mkMerge [
    {
      assertions = [
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
        username = config.system.primaryUser;
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
