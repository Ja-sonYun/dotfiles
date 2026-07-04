{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # Debugging
    cargo-flamegraph

    # Code
    pmd

    # Binary analysis
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
}
