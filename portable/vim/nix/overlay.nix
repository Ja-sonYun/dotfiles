{ inputs
, vim ? null
, config ? {
    useGo = false;
    useRust = false;
    usePython = false;
    useNode = false;
    useLua = false;
    useNix = false;
    useTerraform = false;
    useCxx = false;
    useMarkdown = false;
    useShell = false;
    useRuby = false;
    useSwift = false;
    useMakefile = false;
    useCopilot = false;
    useHarper = false;
    useAmber = false;
    useSkk = false;
  }
,
}:
final: prev:
let
  pkgs = final;
  unstable = import inputs.nixpkgs-unstable {
    inherit (final) system;
    config.allowUnfree = true;
  };

  mkVimPlugin =
    src: pname:
    (unstable.vimUtils.buildVimPlugin {
      inherit pname src;
      version = src.lastModifiedDate or "0";
    }).overrideAttrs
      (_: {
        doCheck = false;
      });

  effectiveVim =
    let
      vim-full-base = unstable.vim-full.override {
        darwinSupport = pkgs.stdenv.hostPlatform.isDarwin;
        guiSupport = "none";
      };
    in
    if vim == null then
      vim-full-base
    else
      vim-full-base.overrideAttrs (old: {
        version = vim.rev;
        src = pkgs.fetchFromGitHub {
          owner = "vim";
          repo = "vim";
          rev = vim.rev;
          sha256 = vim.sha256;
        };
      });

  allPlugins =
    with unstable.vimPlugins;
    [
      # Plugins from nixpkgs
      splitjoin-vim
      vim-tmux-navigator
      vim-commentary
      vim-surround
      vim-repeat
      vim-abolish
      vim-fugitive
      vim-rhubarb
      vim-gitgutter
      vim-cue

      undotree
      tagbar
    ]
    ++ [
      # Plugins from flake inputs
      (mkVimPlugin inputs.vim-lsp "vim-lsp")
      (mkVimPlugin inputs.vim-eskk "vim-eskk")
    ]
    ++ pkgs.lib.optionals config.useCopilot [
      copilot-vim
    ]
    ++ pkgs.lib.optionals config.useMarkdown [
      markdown-preview-nvim
    ];

  # TODO:
  myPluginsFromGit = [
    # (mkVimPlugin inputs.vim-lsp "vim-lsp")
  ];

  # Aggregate plugin set for packaged Vim
  packagedPlugins = allPlugins ++ myPluginsFromGit;

  commonPackages =
    with pkgs;
    [
      (if pkgs ? git-wrapped then pkgs.git-wrapped else pkgs.git)
      cacert
      ripgrep
      gh
      fzf
      universal-ctags
      gnumake
      gawk
    ]
    ++ pkgs.lib.optionals config.useCopilot [ (nodejs_22.override { enableNpm = false; }) ];

  amberPackagesOpt = pkgs.lib.optionals config.useAmber (
    with pkgs;
    [
      amber-lang
    ]
  );

  skkPackagesOpt = pkgs.lib.optionals config.useSkk (
    with pkgs;
    [
      skkDictionaries.l
    ]
  );

  makefilePackagesOpt = pkgs.lib.optionals config.useMakefile (
    with unstable;
    [
      mbake
    ]
  );

  nodePackagesOpt = pkgs.lib.optionals config.useNode (
    with pkgs;
    [
      nodePackages.prettier
      typescript-language-server
    ]
  );

  pythonPackagesOpt = pkgs.lib.optionals config.usePython (
    with pkgs;
    [
      python312
      python312Packages.black
      python312Packages.isort
      pyright
    ]
  );

  luaPackagesOpt = pkgs.lib.optionals config.useLua (
    with pkgs;
    [
      lua-language-server
      stylua
    ]
  );

  rustPackagesOpt = pkgs.lib.optionals config.useRust (
    with pkgs;
    [
      rust-analyzer
      rustfmt
      rustPackages.cargo
      rustPackages.rustc
    ]
  );

  nixPackagesOpt = pkgs.lib.optionals config.useNix (
    with pkgs;
    [
      nixfmt-rfc-style
      nil
    ]
  );

  terraformPackagesOpt = pkgs.lib.optionals config.useTerraform (
    with pkgs;
    [
      terraform
      terraform-ls
    ]
  );

  goPackagesOpt = pkgs.lib.optionals config.useGo (
    with pkgs;
    [
      gopls
      go
    ]
  );

  cxxPackagesOpt = pkgs.lib.optionals config.useCxx (
    with pkgs;
    [
      clang-tools
    ]
  );

  markdownPackagesOpt = pkgs.lib.optionals config.useMarkdown (
    with pkgs;
    [
      # marksman
      nodePackages.prettier
    ]
  );

  shellPackagesOpt = pkgs.lib.optionals config.useShell (
    with pkgs;
    [
      shellcheck
      shfmt
      bash-language-server
    ]
  );

  yamlPackagesOpt = pkgs.lib.optionals config.useYaml (
    with pkgs;
    [
      yaml-language-server
    ]
  );

  vimPackagesOpt = pkgs.lib.optionals config.useVim (
    with pkgs;
    [
      vim-language-server
    ]
  );

  awkPackagesOpt = pkgs.lib.optionals config.useAwk (
    with pkgs;
    [
      awk-language-server
    ]
  );

  rubyPackagesOpt = pkgs.lib.optionals config.useRuby (
    with pkgs;
    [
      ruby
      ruby-lsp
      rufo
    ]
  );

  swiftPackagesOpt = pkgs.lib.optionals config.useSwift (
    with pkgs;
    [
      swift-format
    ]
  );

  harperPackagesOpt = pkgs.lib.optionals config.useHarper (
    with pkgs;
    [
      harper
    ]
  );

  extraPackages = pkgs.lib.concatLists [
    commonPackages
    amberPackagesOpt
    skkPackagesOpt
    nodePackagesOpt
    pythonPackagesOpt
    luaPackagesOpt
    rustPackagesOpt
    nixPackagesOpt
    terraformPackagesOpt
    goPackagesOpt
    cxxPackagesOpt
    markdownPackagesOpt
    shellPackagesOpt
    yamlPackagesOpt
    vimPackagesOpt
    awkPackagesOpt
    rubyPackagesOpt
    swiftPackagesOpt
    makefilePackagesOpt
    harperPackagesOpt
  ];

  mkRC =
    { cfgDir
    , dev ? false
    ,
    }:
    ''
      " Load user runtime
      set runtimepath^=${cfgDir}
      set runtimepath+=${cfgDir}/after
      source ${cfgDir}/vimrc

      " Optional development packpath for local plugins
      ${pkgs.lib.optionalString dev ''
        set packpath^=~/.config/vim-plugins/site
      ''}

      " Optional ekk dictionary path
      ${pkgs.lib.optionalString config.useSkk ''
        let g:eskk#large_dictionary = {
        \   'path': expand('${pkgs.skkDictionaries.l}/share/skk/SKK-JISYO.L'),
        \   'sorted': 1,
        \   'encoding': 'euc-jp',
        \}
      ''}
    '';

  mkVim =
    { name
    , cfgDir
    , plugins
    , paths ? [ ]
    , dev ? false
    ,
    }:
    let
      vimPkg = (
        effectiveVim.customize {
          name = "vim-core";
          vimrcConfig = {
            customRC = mkRC { inherit cfgDir dev; };
            packages.myplugins = {
              start = plugins;
              opt = [ ];
            };
          };
        }
      );

      vimBin = pkgs.lib.getBin vimPkg;
      binPath = pkgs.lib.makeBinPath paths;
    in
    pkgs.symlinkJoin {
      name = name;
      paths = [
        vimBin
        vimPkg
      ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        makeWrapper "$out/bin/vim-core" "$out/bin/${name}" \
          --prefix PATH : ${binPath}

        ln -sf "$out/bin/${name}" "$out/bin/vim"
        ln -sf "$out/bin/${name}" "$out/bin/vi"
      '';
      meta.mainProgram = name;
    };

  vimPkg = mkVim {
    name = "vim-pkg";
    cfgDir = toString ../vim;
    plugins = packagedPlugins;
    paths = extraPackages;
    dev = false;
  };

  vimDev = mkVim {
    name = "vim-dev";
    # Expect a live config in ~/.config/vim-dev for rapid iteration.
    cfgDir = "~/.config/vim-dev";
    plugins = allPlugins;
    paths = extraPackages;
    dev = true;
  };
in
{
  vim-pkg = vimPkg;
  vim-dev = vimDev;
}
