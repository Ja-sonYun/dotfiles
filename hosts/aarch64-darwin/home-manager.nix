{
  hasTag,
  hostname,
  infraSrc,
  username,
  userhome,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./desktop/finder-sidebar.nix
    ./programs/ai-agent-notification.nix
  ]
  ++ lib.optionals (hasTag "gui") [
    ./desktop/seamtype.nix
    ./programs/freecad
  ]
  ++ lib.optionals (hasTag "gui" && hasTag "ai") [
    ./services/slack-ai-integration.nix
  ];

  home = {
    inherit username;
    homeDirectory = userhome;

    stateVersion = "26.05";
  };

  programs.home-manager.enable = true;

  services.autostartApps = lib.optionals (hostname == "Jays-MacBook-Pro-Server") [
    "ChatGPT"
    "OrbStack"
  ];

  home.packages =
    lib.optionals (hasTag "gui") [
      pkgs.ghidra
      pkgs.macnotesapp
    ]
    ++ lib.optionals (hostname == "Jays-MacBook-Pro") [
      (pkgs.callPackage ../../pkgs/darwin/hermes-light {
        modelLabelPatch =
          infraSrc + "/modules-nixhm/services/docker-compose/hermes/patches/model-prefix-label.patch";
      })
    ];

  home.sessionVariables = {
    CONTAINERS_MACHINE_PROVIDER = "applehv";
  };
}
