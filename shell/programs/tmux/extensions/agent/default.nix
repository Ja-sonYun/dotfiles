{
  config,
  lib,
  ...
}:
let
  tmuxRoot = ../..;
  scripts = "${tmuxRoot}/extensions/agent/scripts";
  popupScripts = "${tmuxRoot}/extensions/popup/scripts";
  sharedRootBindings = import ../../shared-root.nix;
  agentFg = "#{?#{@agent_fg},#{@agent_fg},#[fg=color244]}";
  agentBg = "#{?#{@agent_bg},#{@agent_bg},#[bg=color244]}";
  agents = [
    {
      command = "agent";
      key = "c";
    }
    {
      command = "codex";
      key = "x";
    }
    {
      command = config.programs.codex.defaultProfileName;
      key = "1";
      kind = "codex";
    }
    {
      command = "codex-2";
      key = "2";
      kind = "codex";
    }
    {
      command = "codex-work";
      key = "w";
      kind = "codex";
    }
    {
      command = "claude";
      key = "a";
    }
    {
      command = "pi";
      key = "p";
    }
    {
      command = "claude";
      args = [ "--chrome" ];
      label = "claude chrome";
      key = "b";
    }
  ];
  directAgents = lib.filter (agent: agent.command != "agent") agents;
  agentKinds = lib.unique (map (agent: agent.kind or agent.command) directAgents);
  agentDisplayNames = builtins.listToAttrs (
    map (agent: lib.nameValuePair agent.command (agent.displayName or agent.command)) directAgents
  );
  agentCommandMap = lib.concatStringsSep " " (
    lib.unique (map (agent: "${agent.command}=${agent.kind or agent.command}") directAgents)
    ++ map (kind: "${kind}-*=${kind}") agentKinds
  );
  agentMenu =
    "tmux display-menu -T ' agent ' "
    + lib.escapeShellArgs (
      lib.concatMap (
        agent:
        let
          command = lib.escapeShellArgs (
            [
              "direnv"
              "exec"
              "."
              agent.command
            ]
            ++ (agent.args or [ ])
          );
        in
        [
          (agent.label or agent.command)
          agent.key
          "new-window ${lib.escapeShellArg command}"
        ]
      ) agents
    );
in
{
  programs.tmux-menu = {
    menus.menu.items = lib.mkOrder 400 [
      { separator = true; }
      {
        menu = {
          name = "agent";
          shortcut = "a";
          command = "_gen-close-hook agent && direnv exec . agent";
          session = true;
          sessionName = "agent";
          keyTable = "popup-locked-root";
          sessionOnDir = true;
          runOnRoot = ".root";
          runOnGitRoot = true;
          environment = {
            CTRL_C_AS_CLOSE = "1";
            TMUX_AGENT_STATUS = "1";
            TMUX_REMAP_CTRL_D = "C-n";
          };
          position = {
            w = "60%";
            h = "55%";
          };
        };
      }
      {
        menu = {
          name = "all agents";
          shortcut = "A";
          command = "${scripts}/overview";
          background = true;
        };
      }
    ];
  };

  programs.tmux = {
    agentStatusScript = "${scripts}/status";

    extraConfig = ''
      set-option -g @agent_command_map ${lib.escapeShellArg agentCommandMap}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          command: displayName:
          "set-option -g ${lib.escapeShellArg "@agent_display_${command}"} ${lib.escapeShellArg displayName}"
        ) agentDisplayNames
      )}
    '';

    hooks = {
      agentSessionCountsNewWindow = {
        event = "after-new-window";
        command = ''run-shell -b "${scripts}/counts"'';
      };
      agentSessionCountsSelectPane = {
        event = "after-select-pane";
        command = ''run-shell -b "${scripts}/counts"'';
      };
      agentSessionCountsSelectWindow = {
        event = "after-select-window";
        command = ''run-shell -b "${scripts}/counts"'';
      };
      agentSessionCountsSplitWindow = {
        event = "after-split-window";
        command = ''run-shell -b "${scripts}/counts"'';
      };
      agentSessionCountsClientSessionChanged = {
        event = "client-session-changed";
        command = ''run-shell -b "${scripts}/counts"'';
      };
      agentStatusNewSession = {
        event = "after-new-session";
        command = ''run-shell -b "${scripts}/status init #{pane_id} #{q:session_id}"'';
      };
      agentStatusNewWindow = {
        event = "after-new-window";
        command = ''run-shell -b "${scripts}/status init #{pane_id} #{q:session_id}"'';
      };
      agentStatusPaneExited = {
        event = "pane-exited";
        command = ''run-shell -b "${scripts}/status delete #{hook_pane} #{q:@agent_session_id}"'';
      };
      agentStatusPaneDied = {
        event = "pane-died";
        command = ''run-shell -b "${scripts}/status delete #{hook_pane} #{q:@agent_session_id}"'';
      };
      agentStatusWindowUnlinked = {
        event = "window-unlinked";
        command = ''run-shell -b "${scripts}/status refresh"'';
      };
      agentStatusSessionClosed = {
        event = "session-closed";
        command = ''run-shell -b "${scripts}/status refresh"'';
      };
    };

    bindings.c.cases = lib.mkBefore [
      {
        whenEnv = [ "TMUX_AGENT_STATUS" ];
        script = agentMenu;
      }
    ];

    keyTables = {
      all-agents-root = sharedRootBindings // {
        "C-q".command = "switch-client -T all-agents-prefix";
        menuCtrlC = {
          key = "C-c";
          command = "detach-client";
        };
        "C-d".command = "send-keys C-n";
      };

      all-agents-prefix = {
        "C-c".command = "send-keys C-c";
        d.command = "detach-client";
        f.command = "detach-client";
        "C-f".command = "detach-client";
        "C-r".command = "detach-client";
        w.command = "detach-client";
        s.command = "detach-client";
        k.command = "run-shell -b '${config.programs.tmux-menu.showScript} #{q:pane_id} #{q:window_id} #{q:client_name} #{q:pane_current_path}'";
        n.command = "next-window";
        "C-n" = {
          repeat = true;
          command = "next-window";
        };
        p.command = "previous-window";
        "C-p" = {
          repeat = true;
          command = "previous-window";
        };
        l.command = "last-window";
        "0".command = "select-window -t :=0";
        "1".command = "select-window -t :=1";
        "2".command = "select-window -t :=2";
        "3".command = "select-window -t :=3";
        "4".command = "select-window -t :=4";
        "5".command = "select-window -t :=5";
        "6".command = "select-window -t :=6";
        "7".command = "select-window -t :=7";
        "8".command = "select-window -t :=8";
        "9".command = "select-window -t :=9";
        Up.command = "select-pane -U";
        Down.command = "select-pane -D";
        Left.command = "select-pane -L";
        Right.command = "select-pane -R";
        q.command = "display-panes";
        copy = {
          key = "[";
          command = "copy-mode";
        };
        paste = {
          key = "]";
          command = "paste-buffer -p";
        };
        PPage.command = "copy-mode -u";
        z.command = "resize-pane -Z";
        m.command = "switch-client -T popupmove";
        M.command = ''run-shell -b "${popupScripts}/move reset '#{session_name}'"'';
        Any.command = ''display-message "All Agents: window/session changes disabled"'';
      };
    };
  };

  programs.tmux-customize = {
    sessions.agent.group = "agent";
    segments.reconcile = ''"${scripts}/reconcile" >/dev/null 2>&1 &'';
    groups = {
      normal.status.right = lib.mkBefore [ "reconcile" ];
      agent = {
        match.env = "TMUX_AGENT_STATUS";
        priority = 10;
        status = {
          enable = true;
          position = "bottom";
          bg = "default";
          style = "bg=default";
          left = [
            "reconcile"
            "space"
          ];
          right = [ ];
        };
        window = {
          format = "#[bg=default]${agentFg}▐${agentBg}#[fg=black]#I:#{?#{==:#{session_name},_popup_all_agents},#{b:@agent_project} · ,}#W${agentFg}#[bg=default]▌#[default]";
          currentFormat =
            let
              highlightColor = "magenta";
            in
            "${agentBg}#[fg=${highlightColor}]▌#[fg=black]#I:#{?#{==:#{session_name},_popup_all_agents},#{b:@agent_project} · ,}#{@agent_display_name}:#{@agent_state}${agentFg}#[fg=${highlightColor}]▐#[default]";
        };
      };
    };
  };
}
