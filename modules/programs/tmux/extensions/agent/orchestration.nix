{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux.extensions.agent.orchestration;
  hub = config.programs.ai-agents.extensions.orchestration;
  embeddedPane = "#{!=:#{@agent_hub_embedded},}";
  attach = pkgs.writeShellApplication {
    name = "agent-hub-attach";
    runtimeInputs = [ config.programs.tmux.package ];
    text = ''
      tmux -S "$1" set-option -s "@agent_hub_client_$$" "$3"
      exec tmux -S "$1" attach-session -t "$2"
    '';
  };
  tmuxConfig = (pkgs.formats.json { }).generate "agent-hub-tmux.json" {
    allowedSessionPatterns = [ ".*" ];
    sendKeys.enable = false;
    capture = {
      defaultLines = 200;
      maxLines = 5000;
      maxOutputBytes = 65536;
    };
    instructions = "Observe registered agent panes across the user's projects. Never send input.";
  };
  adapterSource = pkgs.replaceVars ./orchestration.mts {
    tmuxMcp = lib.getExe pkgs.tmux-mcp;
    attach = lib.getExe attach;
    inherit tmuxConfig;
  };
  observationSource = pkgs.replaceVars ./orchestration-observe.mts {
    tmux = lib.getExe config.programs.tmux.package;
  };
  adapterPackage =
    pkgs.runCommand "agent-hub-tmux-adapter"
      {
        nativeBuildInputs = [ pkgs.typescript ];
      }
      ''
        cp ${adapterSource} orchestration.mts
        cp ${observationSource} orchestration-observe.mts
        ln -s ${pkgs.pi-runtime}/lib/node_modules/dotfiles-pi/node_modules node_modules
        tsc --strict --noUncheckedIndexedAccess --exactOptionalPropertyTypes --noEmitOnError --target ES2022 --module NodeNext \
          --moduleResolution NodeNext --types node --outDir "$out" orchestration.mts
      '';
  adapter = "${adapterPackage}/orchestration.mjs";
in
{
  options.programs.tmux.extensions.agent.orchestration = {
    enable = lib.mkEnableOption "agent monitor popup and session attachment";
    menuKey = lib.mkOption {
      type = lib.types.str;
      default = "o";
      description = "Shortcut in the tmux main menu for the agent monitor.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          hub.enable && config.programs.tmux.extensions.agent.enable && config.programs.tmux-menu.enable;
        message = "The orchestration popup requires the agent monitor, tmux agent integration and tmux-menu.";
      }
    ];
    programs = {
      ai-agents.extensions.orchestration.tmuxAdapter = toString adapter;
      tmux = {
        bindings = {
          f.cases = lib.mkBefore [
            {
              whenFormat = embeddedPane;
              command = "send-keys C-f";
            }
            {
              whenFormat = "#{m:_popup_*_agent-hub,#{session_name}}";
              command = "detach-client";
            }
          ];
          C-f.cases = lib.mkBefore [
            {
              whenFormat = embeddedPane;
              command = "send-keys C-f";
            }
          ];
          C-c.cases = lib.mkBefore [
            {
              whenFormat = embeddedPane;
              command = "send-keys C-q C-c";
            }
          ];
        }
        // lib.optionalAttrs config.programs.tmux.extensions.popup.enable (
          lib.genAttrs
            [
              "w"
              "s"
              "c"
              "n"
              "C-n"
              "p"
              "C-p"
              "%"
              "menuQuote"
              "!"
              "*"
              "@"
              "g"
              "C-r"
              "d"
            ]
            (key: {
              cases = lib.mkBefore [
                (
                  {
                    whenFormat = embeddedPane;
                    command = "send-keys C-f";
                  }
                  //
                    lib.optionalAttrs
                      (lib.elem key [
                        "n"
                        "C-n"
                        "p"
                        "C-p"
                      ])
                      {
                        unlessEnv = [ "TMUX_POPUP_KEEP_OPEN" ];
                      }
                )
              ];
            })
        );
        keyTables = {
          agent-hub-view.Any.command = "send-keys";
          agent-hub-input.Any.command = "send-keys";
        }
        //
          lib.genAttrs
            (
              [ "common-root" ]
              ++ lib.optionals config.programs.tmux.extensions.popup.enable [
                "popup-root"
                "popup-locked-root"
              ]
            )
            (_: {
              C-f.cases = [
                { command = "send-keys C-f"; }
              ];
              menuCtrlC.cases = lib.mkBefore [
                {
                  whenFormat = "#{m:_popup_*_agent-hub,#{session_name}}";
                  command = "send-keys C-c";
                }
              ];
            });
      };
      tmux-menu.menus.menu.items = lib.mkOrder 410 [
        {
          menu = {
            name = "agent monitor";
            shortcut = cfg.menuKey;
            command = "${hub.launchCommand} tui";
            session = true;
            sessionName = "agent-hub";
            environment = {
              CTRL_C_AS_CLOSE = "1";
              AGENT_HUB_POPUP = "1";
            };
            keyTable =
              if config.programs.tmux.extensions.popup.enable then "popup-locked-root" else "common-root";
            position = {
              w = "90%";
              h = "85%";
              x = "C";
              y = "C";
            };
          };
        }
      ];
      tmux-customize.groups.agent-hub-popup = {
        match.env = "AGENT_HUB_POPUP";
        priority = 20;
        status.enable = false;
        window = config.programs.tmux.extensions.agent.windowStyles;
      };
    };
  };
}
