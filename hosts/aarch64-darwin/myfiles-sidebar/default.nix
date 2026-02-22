{ pkgs, lib, userhome, ... }:
let
  myfilesPath = "${userhome}/Documents/MyFiles";

  finderSidebarEditor = pkgs.python312Packages.buildPythonPackage {
    pname = "FinderSidebarEditor";
    version = "1.0.0";
    src = pkgs.fetchFromGitHub {
      owner = "robperc";
      repo = "FinderSidebarEditor";
      rev = "master";
      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    pyproject = true;
    build-system = [ pkgs.python312Packages.setuptools ];
    dependencies = with pkgs.python312Packages; [
      pyobjc
    ];
    doCheck = false;
  };

  pythonEnv = pkgs.python312.withPackages (ps: [
    finderSidebarEditor
    ps.python-dateutil
  ]);

  sidebar-manager = pkgs.writeScriptBin "myfiles-sidebar-manager" ''
    #!${pythonEnv}/bin/python3

    from FinderSidebarEditor import FinderSidebar
    from datetime import datetime
    from dateutil.relativedelta import relativedelta
    import os

    BASE_PATH = "${myfilesPath}"

    def get_month_folder(offset=0):
        date = datetime.now() + relativedelta(months=offset)
        return date.strftime("%Y.%m")

    def main():
        current = get_month_folder(0)
        prev = get_month_folder(-1)
        old = get_month_folder(-2)

        # Create current month folder
        current_path = os.path.join(BASE_PATH, current)
        os.makedirs(current_path, exist_ok=True)

        sidebar = FinderSidebar()

        # Remove 2 months ago from sidebar
        try:
            sidebar.remove(old)
        except:
            pass

        # Add current month if not exists
        try:
            sidebar.add(current_path)
        except:
            pass

        # Add previous month if not exists
        prev_path = os.path.join(BASE_PATH, prev)
        if os.path.exists(prev_path):
            try:
                sidebar.add(prev_path)
            except:
                pass

    if __name__ == "__main__":
        main()
  '';

  sidebar-manager-cron = pkgs.writeShellApplication {
    name = "myfiles-sidebar-cron";
    runtimeInputs = [ sidebar-manager ];
    text = ''
      myfiles-sidebar-manager
    '';
  };
in
{
  home.packages = [ sidebar-manager ];

  launchd.agents.myfiles-sidebar = {
    enable = true;
    config = {
      Label = "com.user.myfiles-sidebar";
      ProgramArguments = [ "${sidebar-manager-cron}/bin/myfiles-sidebar-cron" ];
      StartCalendarInterval = [{
        Hour = 0;
        Minute = 5;
      }];
      RunAtLoad = true;
      StandardOutPath = "/tmp/myfiles-sidebar.log";
      StandardErrorPath = "/tmp/myfiles-sidebar.log";
    };
  };
}
