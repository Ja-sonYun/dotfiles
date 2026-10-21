{ pkgs, config, ... }:
let
  extension = pkgs.stdenv.hostPlatform.extensions.sharedLibrary;
in
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
      %OPENAI_API_KEY=`%CAPI_KEY`
      decai -e baseurl=`%LLM_DOMAIN`
      decai -e model=`%ZDR_LLM_MODEL`
    '';

    plugins = {
      "libcore_pdd${extension}" = "${pkgs.r2dec}/lib/radare2/last/libcore_pdd${extension}";
      "libcore_r2ghidra${extension}" = "${pkgs.r2ghidra}/lib/radare2/last/libcore_r2ghidra${extension}";
      "libcore_r2mcp${extension}" = "${pkgs.r2mcp}/lib/radare2/last/libcore_r2mcp${extension}";
    };

    env = {
      CAPI_KEY._secret = config.age.secrets."capi-key".path;
      LLM_DOMAIN._secret = config.age.secrets."llm-domain".path;
    };

    decai = {
      enable = true;
      settings = {
        api = "openai";
        cmds = "pdd,pdg";
      };
    };
  };
}
