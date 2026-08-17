{ inputs }:
{
  # Override swift-format to skip build on Linux
  swift-format-skip-linux =
    _final: prev:
    prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
      swift-format = prev.runCommand "swift-format-dummy" { } "mkdir -p $out/bin";
    };

  uv-as-package = final: prev: {
    uv = prev.uv.overrideAttrs (oldAttrs: {
      passthru = (oldAttrs.passthru or { }) // {
        asPackage =
          {
            name,
            root,
            entrypoint,
            python ? final.python312,
            runtimeInputs ? [ ],
          }:
          let
            entrypointParts = final.lib.splitString ":" entrypoint;
            entrypointModule =
              if builtins.length entrypointParts == 2 then
                builtins.elemAt entrypointParts 0
              else
                throw "uv.asPackage entrypoint must be module:function";
            entrypointFunction = builtins.elemAt entrypointParts 1;
            workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = root; };
            overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
            pythonSet =
              (final.callPackage inputs.pyproject-nix.build.packages { inherit python; }).overrideScope
                (
                  final.lib.composeManyExtensions [
                    inputs.pyproject-build-systems.overlays.wheel
                    overlay
                  ]
                );
            virtualenv = pythonSet.mkVirtualEnv "${name}-env" workspace.deps.default;
            launcher = final.writeText "${name}-entrypoint.py" ''
              import importlib
              import sys

              sys.path.insert(0, ${builtins.toJSON (toString root)})
              module = importlib.import_module(${builtins.toJSON entrypointModule})
              main = getattr(module, ${builtins.toJSON entrypointFunction})
              raise SystemExit(main())
            '';
          in
          final.writeShellScriptBin name ''
            ${final.lib.optionalString (runtimeInputs != [ ]) ''
              export PATH=${final.lib.makeBinPath runtimeInputs}:$PATH
            ''}
            exec ${virtualenv}/bin/python ${launcher} "$@"
          '';
      };
    });
  };

  tmux-pin = _final: prev: {
    tmux = prev.tmux.overrideAttrs (oldAttrs: {
      version = "3.7b";
      src = prev.fetchFromGitHub {
        owner = "tmux";
        repo = "tmux";
        tag = "3.7b";
        hash = "sha256-CTq06XP997M0ODxQihTq34dI9H6jSRLUXLYuTWOwDpc=";
      };
      patches = (oldAttrs.patches or [ ]) ++ [
        # TODO: Remove this backport when stable tmux includes #5350 and #5398.
        ./patches/tmux-3.7b-popup-flicker.patch
      ];
      buildInputs =
        oldAttrs.buildInputs
        ++ prev.lib.optionals prev.stdenv.hostPlatform.isDarwin [
          prev.jemalloc
        ];
      configureFlags =
        oldAttrs.configureFlags
        ++ prev.lib.optionals prev.stdenv.hostPlatform.isDarwin [
          "--enable-jemalloc"
        ];
    });
  };

  # Override upstream packages using our local pkgs/* definitions
  unstable-pkgs-override = _final: _prev: {
    # yabai = final.callPackage ../pkgs/yabai { inherit prev final; };
  };
}
