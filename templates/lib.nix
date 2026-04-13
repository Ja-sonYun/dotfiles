# Composable shell fragment library.
# Each mk* function returns { packages, shellHook?, env? }.
# Use `compose` to merge fragments into a single mkShell call.
{
  pkgs,
  pkgs-terraform ? null,
  system ? null,
}:
let
  mkPython =
    { version }:
    let
      pythonPkg = pkgs.${"python${version}"};
    in
    {
      packages = [
        pythonPkg
        pkgs.uv
      ];
      shellHook = ''
        set -a
        [ -f ".env" ] && source .env
        set +a
        [ ! -d "$UV_PROJECT_ENVIRONMENT" ] && uv venv "$UV_PROJECT_ENVIRONMENT" --python "$UV_PYTHON"
        source "$UV_PROJECT_ENVIRONMENT/bin/activate"
      '';
      env = {
        UV_PROJECT_ENVIRONMENT = ".venv";
        UV_PYTHON = "${pythonPkg}/bin/python3";
        UV_NO_SYNC = "1";
        UV_PYTHON_DOWNLOADS = "never";
      };
    };

  mkNode = {
    packages = with pkgs; [
      nodejs_20
      pnpm
      yarn
    ];
  };

  mkRust =
    {
      extraTargets ? [ ],
      extraPackages ? [ ],
    }:
    let
      toolchain =
        if extraTargets == [ ] then
          pkgs.rustToolchain
        else
          pkgs.rustToolchain.override { targets = extraTargets; };
    in
    {
      packages =
        with pkgs;
        [
          toolchain
          openssl
          pkg-config
          cargo-deny
          cargo-edit
          cargo-watch
          rust-analyzer
        ]
        ++ extraPackages;
      env = {
        RUST_SRC_PATH = "${toolchain}/lib/rustlib/src/rust/library";
      };
    };

  mkTerraform = {
    packages = [ pkgs-terraform.terraform ];
  };

  mkAws = {
    packages = [ pkgs.awscli2 ];
  };

  mkGcloud = {
    packages = with pkgs; [
      google-cloud-sdk
      (google-cloud-sdk.withExtraComponents (
        with google-cloud-sdk.components;
        [
          gke-gcloud-auth-plugin
        ]
      ))
      kubernetes-helm
    ];
  };

  mkAzure = {
    packages = [ pkgs.azure-cli ];
  };

  mkGo = {
    packages = with pkgs; [
      go
      gotools
      golangci-lint
    ];
  };

  mkElixir = {
    packages =
      with pkgs;
      [
        elixir
        git
        nodejs_20
      ]
      ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
        pkgs.gigalixir
        pkgs.inotify-tools
        pkgs.libnotify
      ]
      ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
        pkgs.terminal-notifier
      ];
  };

  mkCCpp = {
    packages =
      with pkgs;
      [
        clang-tools
        astyle
        cmake
        codespell
        conan
        cppcheck
        doxygen
        gtest
        lcov
        vcpkg
        vcpkg-tool
        bear
        ccls
        ninja
        gcc
        cflow
      ]
      ++ (if system == "aarch64-darwin" then [ ] else [ pkgs.gdb ]);
  };

  mkZig = {
    packages = with pkgs; [
      zig
      zls
      lldb
    ];
  };

  mkRuby = {
    packages = [ pkgs.ruby_3_3 ];
  };

  compose =
    fragments:
    pkgs.mkShell {
      packages = builtins.concatLists (map (f: f.packages or [ ]) fragments);
      shellHook = builtins.concatStringsSep "\n" (
        builtins.filter (s: s != "") (map (f: f.shellHook or "") fragments)
      );
      env = builtins.foldl' (acc: f: acc // (f.env or { })) { } fragments;
    };
in
{
  inherit
    mkPython
    mkNode
    mkRust
    mkTerraform
    mkAws
    mkGcloud
    mkAzure
    mkGo
    mkElixir
    mkCCpp
    mkZig
    mkRuby
    compose
    ;
}
