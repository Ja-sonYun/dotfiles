{ pkgs, ... }: {
  home.packages = with pkgs; [
    visidata
  ];
  home.file.visidataconf = {
    target = ".visidatarc";
    text = ''
      TableSheet.bindkey('i', 'edit-cell')

      Sheet.addCommand('^D', 'scroll-halfpage-down', 'cursorDown(nScreenRows//2); sheet.topRowIndex += nScreenRows//2')
      Sheet.addCommand('^U', 'scroll-halfpage-up', 'cursorDown(-nScreenRows//2); sheet.topRowIndex -= nScreenRows//2')
    '';
  };
}
