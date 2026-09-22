{
  lib,
  pkgs,
  ...
}:
{
  options.programs.ai-agents.extensions.formatLint = {
    enable = lib.mkEnableOption "post-edit formatting and lint feedback";
    package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = pkgs.callPackage ./pkgs { };
      description = "Formatter and lint executable used by the post-edit hook chain.";
    };
  };

}
