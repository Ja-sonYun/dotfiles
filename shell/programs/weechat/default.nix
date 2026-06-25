{ pkgs, ... }:
{
  home.packages = with pkgs; [
    (weechat.override {
      configure =
        { availablePlugins, ... }:
        {
          scripts = with pkgs.weechatScripts; [
            wee-slack
            autosort
            weechatScripts.weechat-go
          ];
          # ++ [
          #   (mkScript (toString ./plugins/vimmode))
          # ];
          plugins = builtins.attrValues (builtins.removeAttrs availablePlugins [ "php" ]);
        };
    })
  ];

  # home.file.weechatconfig = {
  #   recursive = true;
  #   target = ".config/weechat";
  #   source = toString ./config;
  # };
}
