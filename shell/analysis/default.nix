{ pkgs, system, ... }:
{
  home.packages = with pkgs; [
    # Debugging
    cargo-flamegraph

    # Code
    pmd

    # Binary analysis
    radare2
    rizin
    binsider

    # Cloud Infrastructure
    # checkov
    trivy

    # API Related
    nmap
    sqlmap

    # API - Fuzz
    # wfuzz
    ffuf
    gospider
    arjun

    # Network
    trippy

    # JWT
    jwt-cli
    jwt-hack

    # Packet
    tcpdump
    tshark

    # mitmproxy  # TODO
    # Won't install gui version
    # wireshark

    # Password
    # stable.john
  ];
  # ++ pkgs.lib.optional (system == "x86_64-linux") [
  #   rr
  #   gdb
  # ];

  home.file.radare2 = {
    recursive = true;
    target = ".config/radare2";
    source = toString ./configs/radare2;
  };
}
