{
  config,
  lib,
  nixlib,
  agenix,
  ...
}:
let
  cfg = config.services.profiles.nixhmContainer;
  instances = cfg.instance or { };
  servicesFor = instance: instance.services or { };
  activeServicesFor =
    instance: lib.filterAttrs (_: service: service.enable or true) (servicesFor instance);
  serviceVolumes = lib.mapAttrsToList (
    instanceId: instance:
    lib.mapAttrs' (
      name: _:
      lib.nameValuePair "${instanceId}-${name}-data" {
        mountPoint = lib.mkDefault "/var/lib/${name}";
      }
    ) (activeServicesFor instance)
  ) instances;
  containerInstances = lib.mapAttrs (
    instanceId: instance:
    let
      volumes = instance.volumes or [ ];
      serviceNames = lib.filter (
        name:
        !builtins.any (
          volume: config.services.nixosContainer.volume.${volume}.mountPoint == "/var/lib/${name}"
        ) volumes
      ) (builtins.attrNames (activeServicesFor instance));
      networking = instance.networking or { };
      firewall = networking.firewall or { };
      ports = instance.ports or { };
    in
    removeAttrs instance [
      "services"
      "ports"
    ]
    // {
      enable = instance.enable or (activeServicesFor instance != { });
      volumes =
        volumes
        ++ map (name: "${instanceId}-${name}-data") serviceNames
        ++ lib.optional (cfg.identityFile != null) "agenix";
      networking = networking // {
        firewall = firewall // {
          allowedTCPPorts = lib.unique ((firewall.allowedTCPPorts or [ ]) ++ (ports.tcp or [ ]));
          allowedUDPPorts = lib.unique ((firewall.allowedUDPPorts or [ ]) ++ (ports.udp or [ ]));
        };
      };
      services.profiles = lib.mapAttrs (_: service: { enable = true; } // service) (servicesFor instance);
    }
  ) instances;

  baseModules = [
    nixlib.serviceModules
    agenix.nixosModules.default
    { nixpkgs.overlays = builtins.attrValues nixlib.overlays; }
    {
      age.identityPaths = lib.mkForce (lib.optional (cfg.identityFile != null) "/var/lib/agenix/id_rsa");
    }
  ];
in
{
  options.services.profiles.nixhmContainer = lib.mkOption {
    default = { };
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf lib.types.anything;
      options.identityFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host identity file mounted read-only for agenix.";
      };
    };
    description = "Like services.nixosContainer, but service bodies are nixhm presets.";
  };

  config = lib.mkIf (instances != { }) {
    services.nixosContainer = {
      modules = baseModules ++ (cfg.modules or [ ]);
      instance = containerInstances;
      volume = lib.mkMerge (
        serviceVolumes
        ++ [
          (cfg.volume or { })
          {
            agenix = lib.mkIf (cfg.identityFile != null) {
              mountPoint = "/var/lib/agenix/id_rsa";
              hostPath = cfg.identityFile;
              readOnly = true;
            };
          }
        ]
      );
    };
  };
}
