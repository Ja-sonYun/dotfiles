{
  config,
  lib,
  paths,
  pkgs,
  ...
}:

let
  inherit (lib)
    attrValues
    filter
    filterAttrs
    flatten
    mapAttrsToList
    mkDefault
    mkEnableOption
    mkMerge
    mkOption
    nameValuePair
    optionalString
    optionals
    types
    unique
    ;
  cfg = config.services.nixosContainer;
  cacheDir = paths.cache;

  serviceOptions = [
    "enable"
    "_vm"
  ];

  serviceAttrs = removeAttrs cfg [
    "instance"
    "modules"
    "volume"
  ];

  enabledServices = filterAttrs (_: service: service.enable) serviceAttrs;

  idOf = service: service._vm.instanceId;

  serviceInstanceIds = unique (map idOf (attrValues enabledServices));
  usedIds = builtins.attrNames (filterAttrs (_: instance: instance.enable) cfg.instance);

  servicesFor = id: filterAttrs (_: service: idOf service == id) enabledServices;

  profileConfig = service: removeAttrs service serviceOptions;

  instanceConfig =
    id:
    removeAttrs cfg.instance.${id} [
      "enable"
      "stateVersion"
      "cpus"
      "memory"
      "volumes"
    ];

  mkGuest =
    id: services:
    import "${pkgs.path}/nixos" {
      system = "aarch64-linux";
      configuration = { modulesPath, ... }: {
        imports = [
          (modulesPath + "/virtualisation/docker-image.nix")
        ]
        ++ cfg.modules;

        config = mkMerge (
          [
            {
              system.stateVersion = mkDefault cfg.instance.${id}.stateVersion;
              networking = {
                hostName = mkDefault "mac-services-${id}";
                resolvconf.enable = mkDefault false;
                firewall = {
                  allowedTCPPorts = unique (flatten (map (s: s._vm.allowedTCPPorts) (attrValues services)));
                  allowedUDPPorts = unique (flatten (map (s: s._vm.allowedUDPPorts) (attrValues services)));
                };
              };
            }
            (instanceConfig id)
          ]
          ++ mapAttrsToList (name: service: {
            services.${name} = (profileConfig service) // {
              enable = true;
            };
          }) services
        );
      };
    };

  mkImage =
    id: services:
    let
      guest = mkGuest id services;
      rootfs =
        pkgs.runCommand "mac-services-${id}-rootfs"
          {
            nativeBuildInputs = [
              pkgs.gnutar
              pkgs.xz
            ];
          }
          ''
            mkdir -p "$out"
            for tarball in ${guest.config.system.build.tarball}/tarball/*.tar.xz; do
              tar --delay-directory-restore -xJf "$tarball" -C "$out" --no-same-owner
            done
          '';
      rawImage = pkgs.dockerTools.buildImage {
        name = "mac-services-${id}";
        tag = "latest";
        architecture = "arm64";
        compressor = "none";
        config.Cmd = [ "/init" ];
        extraCommands = ''
          cp -a ${rootfs}/. .
        '';
      };
    in
    pkgs.runCommand "docker-image-mac-services-${id}-apple-container.tar"
      {
        nativeBuildInputs = [
          pkgs.skopeo
        ];
      }
      ''
        skopeo --insecure-policy copy \
          docker-archive:${rawImage} \
          oci-archive:"$out":mac-services-${id}:latest
      '';

  containerBin = "${config.homebrew.prefix}/bin/container";
  jqBin = "${pkgs.jq}/bin/jq";

  # marks a container as managed by this module so the reaper only ever touches our own
  managedLabel = "managed-by=nixosContainer";

  mkShellArrayItems = args: lib.concatMapStrings (arg: "          ${lib.escapeShellArg arg}\n") args;

  automaticVolumes =
    id: services:
    filterAttrs (
      name: _:
      !builtins.any (
        volume: cfg.volume.${volume}.mountPoint == "/var/lib/${name}"
      ) cfg.instance.${id}.volumes
    ) services;

  mkRunArgs =
    id: services: guest:
    let
      inst = cfg.instance.${id};
      tcpPorts = guest.config.networking.firewall.allowedTCPPorts;
      udpPorts = guest.config.networking.firewall.allowedUDPPorts;
    in
    [
      "--name"
      id
      "--label"
      managedLabel
      "--cap-add"
      "ALL"
      "--tmpfs"
      "/run"
      "--tmpfs"
      "/tmp"
    ]
    ++ optionals (inst.cpus != null) [
      "--cpus"
      (toString inst.cpus)
    ]
    ++ optionals (inst.memory != null) [
      "--memory"
      inst.memory
    ]
    ++ flatten (
      mapAttrsToList (name: _: [
        "--volume"
        "${id}-${name}-data:/var/lib/${name}"
      ]) (automaticVolumes id services)
    )
    ++ flatten (
      map (
        volId:
        let
          def = cfg.volume.${volId};
        in
        [
          "--volume"
          "${
            if def.hostPath != null then def.hostPath else volId
          }:${def.mountPoint}${lib.optionalString def.readOnly ":ro"}"
        ]
      ) (unique inst.volumes)
    )
    ++ flatten (
      map (port: [
        "--publish"
        "127.0.0.1:${toString port}:${toString port}/tcp"
      ]) tcpPorts
    )
    ++ flatten (
      map (port: [
        "--publish"
        "127.0.0.1:${toString port}:${toString port}/udp"
      ]) udpPorts
    );

  mkAgent =
    id: services:
    let
      guest = mkGuest id services;
      image = mkImage id services;
      imageRef = "mac-services-${id}:latest";
      volumes =
        (mapAttrsToList (name: _: "${id}-${name}-data") (automaticVolumes id services))
        ++ (filter (volId: cfg.volume.${volId}.hostPath == null) (unique cfg.instance.${id}.volumes));
    in
    nameValuePair "appleContainer-${id}" {
      serviceConfig = {
        Label = "com.server.apple-container.${id}";
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        StandardOutPath = "${cacheDir}/logs/apple-container-${id}.out.log";
        StandardErrorPath = "${cacheDir}/logs/apple-container-${id}.err.log";
      };

      script = ''
        #!/usr/bin/env bash
        set -euo pipefail

        mkdir -p ${lib.escapeShellArg "${cacheDir}/logs"}

        container=${lib.escapeShellArg containerBin}
        image=${lib.escapeShellArg "${image}"}
        name=${lib.escapeShellArg id}

        if [ ! -x "$container" ]; then
          echo "[nixosContainer] '$container' not found yet. Install it, then re-run 'darwin-rebuild switch' (or 'make deploy'). Skipping for now."
          exit 0
        fi

        # require container >= 1.0.0
        ver="$("$container" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [ -z "''${ver%%.*}" ] || [ "''${ver%%.*}" -lt 1 ]; then
          echo "[nixosContainer] requires container >= 1.0.0 (found: ''${ver:-unknown}). Upgrade via Homebrew, then re-run 'darwin-rebuild switch' (or 'make deploy'). Skipping for now."
          exit 0
        fi

        if ! "$container" system status >/dev/null 2>&1; then
          "$container" system start --enable-kernel-install --timeout 60
        fi

        "$container" image load --input "$image"

        volumes=(
        ${mkShellArrayItems volumes}
        )
        for v in ''${volumes[@]+"''${volumes[@]}"}; do
          if ! "$container" volume inspect "$v" >/dev/null 2>&1; then
            "$container" volume create "$v"
          fi
        done

        "$container" delete --force "$name" >/dev/null 2>&1 || true

        run_args=(
        ${mkShellArrayItems (mkRunArgs id services guest)}
        )

        exec "$container" run "''${run_args[@]}" ${lib.escapeShellArg imageRef} /init
      '';
    };

  reapContainers = pkgs.writeShellScript "reap-nixos-containers" ''
    set -euo pipefail

    container=${lib.escapeShellArg containerBin}
    jq=${lib.escapeShellArg jqBin}

    # Skip cleanup when the container daemon is unavailable.
    "$container" system status >/dev/null 2>&1 || exit 0

    keep=(
    ${mkShellArrayItems usedIds}
    )
    in_keep() { local x; for x in ''${keep[@]+"''${keep[@]}"}; do [ "$x" = "$1" ] && return 0; done; return 1; }

    # Delete managed containers that are no longer configured, preserving volumes.
    "$container" ls --all --format json \
      | "$jq" -r '.[] | select(.configuration.labels["managed-by"] == "nixosContainer") | .id' \
      | while read -r cid; do
          in_keep "$cid" || "$container" delete --force "$cid" >/dev/null 2>&1 || true
        done || true

    # Prune managed images that are no longer configured.
    "$container" image ls --format json \
      | "$jq" -r '.[].configuration.name | select(startswith("mac-services-"))' \
      | while read -r ref; do
          id="''${ref#mac-services-}"; id="''${id%:latest}"
          in_keep "$id" || "$container" image delete "$ref" >/dev/null 2>&1 || true
        done || true
  '';

  mkReaper = nameValuePair "appleContainerReaper" {
    serviceConfig = {
      Label = "com.server.apple-container-reaper";
      RunAtLoad = true;
      KeepAlive = false;
      ProcessType = "Background";
      StandardOutPath = "${cacheDir}/logs/apple-container-reaper.out.log";
      StandardErrorPath = "${cacheDir}/logs/apple-container-reaper.err.log";
    };

    script = "exec ${reapContainers}";
  };
in
{
  imports = [ ./profiles/nixhm.nix ];

  options.services.nixosContainer = mkOption {
    default = { };
    type = types.submodule {
      # every key except `instance` is a service
      freeformType = types.attrsOf (
        types.submodule {
          freeformType = types.attrsOf types.anything;
          options = {
            enable = mkEnableOption "NixOS service on Apple Container";
            _vm = mkOption {
              default = { };
              type = types.submodule {
                options = {
                  instanceId = mkOption {
                    type = types.str;
                    default = "default";
                  };

                  allowedTCPPorts = mkOption {
                    type = types.listOf types.port;
                    default = [ ];
                  };

                  allowedUDPPorts = mkOption {
                    type = types.listOf types.port;
                    default = [ ];
                  };
                };
              };
            };
          };
        }
      );
      options = {
        modules = mkOption {
          type = types.listOf types.deferredModule;
          default = [ ];
          description = "Extra NixOS modules for all guests.";
        };

        volume = mkOption {
          default = { };
          description = "Named volume definitions.";
          type = types.attrsOf (
            types.submodule {
              options = {
                mountPoint = mkOption {
                  type = types.str;
                  description = "Guest mount path.";
                };
                readOnly = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Mount the volume read-only.";
                };
                hostPath = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Host path for a bind mount.";
                };
              };
            }
          );
        };

        instance = mkOption {
          default = { };
          type = types.attrsOf (
            types.submodule (
              { name, ... }: {
                freeformType = types.attrsOf types.anything;
                options = {
                  enable = mkEnableOption "this NixOS container instance" // {
                    default = builtins.elem name serviceInstanceIds;
                    defaultText = lib.literalExpression "true when selected by an enabled service";
                  };
                  stateVersion = mkOption {
                    type = types.str;
                    default = "26.05";
                  };

                  # container-level options for Apple `container run`
                  cpus = mkOption {
                    type = types.nullOr types.int;
                    default = null;
                  };

                  memory = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                  };

                  volumes = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Volume IDs to mount.";
                  };
                };
              }
            )
          );
        };
      };
    };
  };

  config = {
    system.activationScripts.userLaunchd.text = mkMerge [
      (lib.mkIf (usedIds != [ ]) (
        lib.mkBefore ''
          /usr/bin/sudo --user=${lib.escapeShellArg config.system.primaryUser} -- /bin/mkdir -p ${lib.escapeShellArg "${cacheDir}/logs"}
        ''
      ))
      (lib.mkIf (usedIds == [ ] && config.system.primaryUser != null) (
        # Clean up after the last container's LaunchAgent has been unloaded.
        lib.mkAfter ''
          /bin/launchctl asuser "$(/usr/bin/id -u -- ${lib.escapeShellArg config.system.primaryUser})" \
            /usr/bin/sudo --user=${lib.escapeShellArg config.system.primaryUser} --set-home -- ${reapContainers}
        ''
      ))
    ];
    assertions = lib.optionals (enabledServices != { }) (
      map (id: {
        assertion = cfg.instance ? ${id};
        message =
          "services.nixosContainer: instance \"${id}\" is referenced by a service "
          + "but not declared in services.nixosContainer.instance"
          + (optionalString (id == "default") " (set _vm.instanceId or declare instance.default)");
      }) serviceInstanceIds
    );

    launchd.user.agents = builtins.listToAttrs (
      lib.optional (usedIds != [ ]) mkReaper ++ map (id: mkAgent id (servicesFor id)) usedIds
    );
  };
}
