{ pkgs, config, ... }:
{
  programs.radare2 = {
    enable = true;

    extraConfig = ''
      e scr.color=1
      e scr.utf8=true
      e scr.utf8.curvy=true
      e asm.bytes=false
      e dbg.hwbp=false
      e cfg.fortunes=false
      e bin.cache=true
      e r2ghidra.sleighhome=${pkgs.r2ghidra}/lib/radare2/last/r2ghidra_sleigh
      decai -e baseurl=`%AI_ADDRESS`
    '';

    plugins = {
      "libcore_pdd.dylib" = "${pkgs.r2dec}/lib/radare2/last/libcore_pdd.dylib";
      "libcore_r2ghidra.dylib" = "${pkgs.r2ghidra}/lib/radare2/last/libcore_r2ghidra.dylib";
    };

    envFiles = {
      OPENAI_API_KEY = config.age.secrets."capi-key".path;
      AI_ADDRESS = config.age.secrets."ai-address".path;
    };

    decai = {
      enable = true;
      settings = {
        api = "openai";
        model = "syn:large:text";
        cmds = "pdd,pdg";
      };
    };
  };
}
