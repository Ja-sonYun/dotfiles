_: {
  programs.gitExtend.commands = [
    {
      path = [ "sync" ];
      help = "Fetch/prune/tags, pull with rebase/autostash, then update submodules.";
      command = ''
        if [ "$#" -ne 0 ]; then
          echo "usage: git sync" >&2
          exit 2
        fi

        git fetch --prune --tags
        git pull --rebase --autostash
        git submodule update --init --recursive
      '';
    }
    {
      path = [
        "branch"
        "gone"
      ];
      help = "List local branches whose upstream is gone.";
      command = ''
        if [ "$#" -ne 0 ]; then
          echo "usage: git branch gone" >&2
          exit 2
        fi

        git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads |
          awk '$2 == "[gone]" { print $1 }'
      '';
    }
    {
      path = [
        "branch"
        "prune-gone"
      ];
      help = "Delete gone local branches that are already merged into HEAD.";
      command = ''
        if [ "$#" -ne 0 ]; then
          echo "usage: git branch prune-gone" >&2
          exit 2
        fi

        current="$(git branch --show-current)"
        merged="$(git branch --format='%(refname:short)' --merged | sort)"

        git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads |
          awk '$2 == "[gone]" { print $1 }' |
          while IFS= read -r branch; do
            [ "$branch" = "$current" ] && continue

            if printf '%s\n' "$merged" | grep -Fxq -- "$branch"; then
              git branch -d "$branch"
            fi
          done
      '';
    }
    {
      path = [ "undo" ];
      help = "Undo last commit, keep changes staged.";
      command = ''
        if [ "$#" -ne 0 ]; then
          echo "usage: git undo" >&2
          exit 2
        fi

        git reset --soft HEAD~1
      '';
    }
    {
      path = [ "track" ];
      help = "Set upstream of current branch (default: origin/<branch>).";
      command = ''
        branch="$(git branch --show-current)"
        if [ -z "$branch" ]; then
          echo "error: detached HEAD" >&2
          exit 1
        fi

        git branch --set-upstream-to="''${1:-origin/$branch}"
      '';
    }
    {
      path = [ "root" ];
      help = "Print repo toplevel and cd into it.";
      command = ''
        set -euo pipefail

        root="$(git rev-parse --show-toplevel)"
        echo "$root"
        if [ -n "''${SHELL_CD_REQUEST_FILE-}" ] && [ -d "$root" ]; then
          printf '%s\n' "$root" >"$SHELL_CD_REQUEST_FILE"
        fi
      '';
    }
    {
      path = [
        "remote"
        "add-upstream"
      ];
      help = "Add the fork parent as 'upstream' remote and fetch it.";
      command = ''
        set -euo pipefail

        if git remote get-url upstream >/dev/null 2>&1; then
          echo "error: remote 'upstream' already exists" >&2
          exit 1
        fi

        parent="$(gh repo view --json parent -q '.parent | select(.) | "\(.owner.login)/\(.name)"')"
        if [ -z "$parent" ]; then
          echo "error: not a fork (no parent repo)" >&2
          exit 1
        fi

        git remote add upstream "git@github.com:$parent.git"
        git fetch upstream
      '';
    }
    {
      path = [
        "stash"
        "staged"
      ];
      help = "Stash staged changes only.";
      command = ''
        git stash push --staged "$@"
      '';
    }
    {
      path = [
        "submodule"
        "fix"
      ];
      help = "Fix broken submodules by removing stale worktrees and git metadata, then reinitializing them.";
      command = ''
        git submodule deinit --all -f || true

        git config --file .gitmodules --name-only --get-regexp '^submodule\..*\.path$' |
          while IFS= read -r key; do
            name="''${key#submodule.}"
            name="''${name%.path}"
            path="$(git config --file .gitmodules --get "$key")"

            case "$name" in
              "" | /* | ../* | */../* | */..)
                echo "error: unsafe submodule name: $name" >&2
                exit 1
                ;;
            esac

            case "$path" in
              "" | /* | ../* | */../* | */..)
                echo "error: unsafe submodule path: $path" >&2
                exit 1
                ;;
            esac

            rm -rf -- "$path" ".git/modules/$name"
          done

        git submodule sync --recursive
        git submodule update --init --recursive --force
      '';
    }
  ];
}
