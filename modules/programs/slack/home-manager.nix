{
  darwinConfig,
  lib,
  ...
}:
let
  cfg = darwinConfig.programs.slack;
in
{
  home.activation.slackIntegration =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
      ''
        ${lib.optionalString (cfg.autoUpdate != null) ''
          run /usr/bin/defaults write com.tinyspeck.slackmacgap AutoUpdate -bool ${lib.boolToString cfg.autoUpdate}
        ''}
      '';
}
