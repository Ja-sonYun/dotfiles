{
  config,
  lib,
  nixlib,
  agenix,
  userhome,
  ...
}:
let
  cfg = config.services.profiles.nixhmContainer;
  instances = cfg.instance or { };
  servicesFor = instance: instance.services or { };
  markerNameFor =
    instanceId: serviceNames:
    if builtins.elem instanceId serviceNames then instanceId else builtins.head serviceNames;
  containerInstances = lib.mapAttrs (
    _: instance:
    removeAttrs instance [
      "services"
      "ports"
    ]
    // {
      volumes = (instance.volumes or [ ]) ++ [ "agenix" ];
      services.profiles = lib.mapAttrs (_: service: service // { enable = true; }) (servicesFor instance);
    }
  ) instances;

  baseModules = [
    nixlib.serviceModules
    agenix.nixosModules.default
    { nixpkgs.overlays = builtins.attrValues nixlib.overlays; }
    { age.identityPaths = lib.mkForce [ "/var/lib/agenix/id_rsa" ]; }
  ];
in
{
  options.services.profiles.nixhmContainer = lib.mkOption {
    default = { };
    type = lib.types.attrsOf lib.types.anything;
    description = "Like services.nixosContainer, but service bodies are nixhm presets.";
  };

  config = lib.mkIf (instances != { }) {
    services.nixosContainer = lib.mkMerge (
      [
        {
          modules = baseModules ++ (cfg.modules or [ ]);

          instance = containerInstances;

          volume.agenix = {
            mountPoint = "/var/lib/agenix";
            hostPath = "${userhome}/.ssh";
          };
        }
      ]
      ++ lib.mapAttrsToList (
        instanceId: instance:
        let
          services = builtins.attrNames (servicesFor instance);
          ports = instance.ports or { };
        in
        lib.optionalAttrs (services != [ ]) {
          ${markerNameFor instanceId services} = {
            enable = true;
            _vm = {
              inherit instanceId;
              allowedTCPPorts = ports.tcp or [ ];
              allowedUDPPorts = ports.udp or [ ];
            };
          };
        }
      ) instances
    );
  };
}
