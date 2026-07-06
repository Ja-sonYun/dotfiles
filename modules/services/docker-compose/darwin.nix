{
  cacheDir,
  enabledProjects,
  lib,
  mkRunScript,
}:
let
  inherit (lib) mapAttrsToList nameValuePair;

  mkAgent =
    name: project:
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
        exec ${mkRunScript name project}
      '';
    };
in
{
  launchd.user.agents = builtins.listToAttrs (mapAttrsToList mkAgent enabledProjects);
}
