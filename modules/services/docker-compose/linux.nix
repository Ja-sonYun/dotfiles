{
  enabledProjects,
  lib,
  mkRunScript,
}:
let
  inherit (lib) mapAttrsToList nameValuePair;

  mkService =
    name: project:
    nameValuePair "dockerCompose-${name}" {
      Unit.Description = "Docker Compose project ${name}";

      Service = {
        ExecStart = "${mkRunScript name project}";
        Restart = "always";
        RestartSec = "10s";
      };

      Install.WantedBy = [ "default.target" ];
    };
in
{
  systemd.user.services = builtins.listToAttrs (mapAttrsToList mkService enabledProjects);
}
