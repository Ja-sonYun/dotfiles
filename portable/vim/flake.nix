{
  description = "Vim derivation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    vim-lsp = {
      url = "github:yegappan/lsp";
      flake = false;
    };
    vim-eskk = {
      url = "github:vim-skk/eskk.vim";
      flake = false;
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self
    , nixpkgs
    , git-hooks
    , ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        builtins.listToAttrs (
          map
            (system: {
              name = system;
              value = f system;
            })
            systems
        );

      # env-driven toggles
      boolEnv =
        name: default:
        let
          v = builtins.getEnv name;
        in
        if v == "" then default else (v == "1" || v == "true" || v == "TRUE" || v == "yes" || v == "on");

      explicitOptions =
        let
          keys = [
            "USE_GO"
            "USE_RUST"
            "USE_PYTHON"
            "USE_NODE"
            "USE_LUA"
            "USE_NIX"
            "USE_TERRAFORM"
            "USE_CXX"
            "USE_MARKDOWN"
            "USE_SHELL"
            "USE_RUBY"
            "USE_SWIFT"
            "USE_MAKEFILE"
            "USE_COPILOT"
            "USE_HARPER"
            "USE_YAML"
            "USE_VIM"
            "USE_AWK"
            "USE_AMBER"
            "USE_SKK"
          ];
          hasVal = key: builtins.getEnv key != "";
        in
        builtins.any hasVal keys;

      cfg =
        if explicitOptions then
          {
            useGo = boolEnv "USE_GO" false;
            useRust = boolEnv "USE_RUST" false;
            usePython = boolEnv "USE_PYTHON" false;
            useNode = boolEnv "USE_NODE" false;
            useLua = boolEnv "USE_LUA" false;
            useNix = boolEnv "USE_NIX" false;
            useTerraform = boolEnv "USE_TERRAFORM" false;
            useCxx = boolEnv "USE_CXX" false;
            useMarkdown = boolEnv "USE_MARKDOWN" false;
            useShell = boolEnv "USE_SHELL" false;
            useRuby = boolEnv "USE_RUBY" false;
            useSwift = boolEnv "USE_SWIFT" false;
            useMakefile = boolEnv "USE_MAKEFILE" false;
            useCopilot = boolEnv "USE_COPILOT" false;
            useHarper = boolEnv "USE_HARPER" false;
            useYaml = boolEnv "USE_YAML" false;
            useVim = boolEnv "USE_VIM" false;
            useAwk = boolEnv "USE_AWK" false;
            useAmber = boolEnv "USE_AMBER" false;
            useSkk = boolEnv "USE_SKK" false;
          }
        else
          {
            useGo = true;
            useRust = true;
            usePython = true;
            useNode = true;
            useLua = true;
            useNix = true;
            useTerraform = true;
            useCxx = true;
            useMarkdown = true;
            useShell = true;
            useRuby = true;
            useSwift = true;
            useMakefile = true;
            useCopilot = true;
            useHarper = true;
            useYaml = true;
            useVim = true;
            useAwk = true;
            useAmber = true;
            useSkk = true;
          };
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            self.overlays.default
          ];
          config.allowUnfree = true;
        };
    in
    {
      overlays.default = import ./nix/overlay.nix {
        inputs = self.inputs;
        config = cfg;
        vim = {
          rev = "v9.2.0010";
          sha256 = "sha256-29dSi9KRs45xc+ZGnLeRPG5x9y8PXSi9XrWH2bNBk6g=";
        };
      };

      checks = forAllSystems (
        system: {
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.nixpkgs-fmt.enable = true;
          };
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.vim-pkg;
          vim = pkgs.vim-pkg;
          vim-dev = pkgs.vim-dev;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            name = "vim-devshell";
            buildInputs = [
              pkgs.vim-dev
            ];
            shellHook = ''
              ln -Tfns "$PWD/vim" ~/.config/vim-dev

              mkdir -p ~/.config/vim-plugins/site/pack/dev/start
              for p in "$PWD"/dev/*; do
                ln -sfn "$p" ~/.config/vim-plugins/site/pack/dev/start/$(basename "$p")
              done

              alias vi='vim-dev' vim='vim-dev'
            '';
          };
        }
      );
    };
}
