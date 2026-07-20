{
  hostname,
  lib,
  pkgs,
  username,
  ...
}:
let
  # The first layout whose displays are all connected is applied.
  displayLayouts = [
    {
      name = "four-monitor";
      displays = [
        {
          name = "lgfullhd";
          matchId = "2748444F-617E-4EC8-B90B-4610ADA398E8";
          resolution = "current";
          scaling = "current";
          origin = "(-1920,-1080)";
        }
        {
          name = "msi";
          matchId = "E6F44C97-DDAD-482C-98C6-EFA94928F713";
          resolution = "current";
          scaling = "current";
          origin = "(0,-1080)";
        }
        {
          name = "lg-hdr-4k-2";
          matchId = "0EE5314F-4774-4BF2-9E18-18DD8C8A872B";
          resolution = "2560x1440";
          scaling = "on";
          origin = "(-2560,0)";
        }
        {
          name = "lg-hdr-4k-1";
          matchId = "82E15DBD-B092-48DA-BA2A-C7E34154FD86";
          resolution = "2560x1440";
          scaling = "on";
          origin = "(0,0)";
        }
      ];
    }
    {
      name = "three-monitor-without-bottom-right";
      displays = [
        {
          name = "lgfullhd";
          matchId = "2748444F-617E-4EC8-B90B-4610ADA398E8";
          resolution = "current";
          scaling = "current";
          origin = "(640,-1080)";
        }
        {
          name = "msi";
          matchId = "E6F44C97-DDAD-482C-98C6-EFA94928F713";
          resolution = "current";
          scaling = "current";
          origin = "(2560,-1080)";
        }
        {
          name = "lg-hdr-4k-2";
          matchId = "0EE5314F-4774-4BF2-9E18-18DD8C8A872B";
          resolution = "2560x1440";
          scaling = "on";
          origin = "(0,0)";
        }
      ];
    }
    {
      name = "built-in";
      displays = [
        {
          name = "built-in";
          matchType = "built-in";
          resolution = "more-space";
          scaling = "on";
        }
      ];
    }
  ];

  displayLayoutsJson = pkgs.writeText "display-layouts.json" (builtins.toJSON displayLayouts);

  apply-display-profile = pkgs.writeShellApplication {
    name = "apply-display-profile";
    runtimeInputs = [
      pkgs.gawk
      pkgs.jq
    ];
    text = ''
      export APPLY_DISPLAY_PROFILE_CONFIG="${displayLayoutsJson}"
      ${builtins.readFile ./apply-display-profile.sh}
    '';
  };
in
{
  environment.systemPackages =
    if hostname == "Jays-MacBook-Pro" then
      [
        apply-display-profile
      ]
    else
      [ ];

  system.activationScripts.postActivation.text = lib.mkIf (hostname == "Jays-MacBook-Pro") (
    lib.mkAfter ''
      uid="$(/usr/bin/id -u "${username}")"
      if /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
        /bin/launchctl asuser "$uid" \
          /usr/bin/sudo --user "${username}" -- \
          "${apply-display-profile}/bin/apply-display-profile" || true
      fi
    ''
  );
}
