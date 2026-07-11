{ pkgs, ... }:
let
  helpers = ''
    set -euo pipefail

    err() {
      echo "error: $*" >&2
      exit 1
    }
    safe() {
      local s
      s="''${1//\//-}"
      s="''${s//#/}"
      echo "$s"
    }

    repo_paths() {
      local root parent base
      root="$(git worktree list --porcelain | sed -n '1s/^worktree //p')" || err "not a git repo"
      parent="$(dirname "$root")"
      base="$(basename "$root")"
      echo "$parent" "$base"
    }

    find_wt_by_branch() {
      local br="$1"
      git worktree list --porcelain | awk -v br="$br" '
        $1=="worktree"{p=$2}
        $1=="branch" && $2=="refs/heads/"br{print p; exit}
      '
    }

    default_wt_path_for_branch() {
      local br="$1"
      read -r parent base < <(repo_paths)
      echo "''${parent}/''${base}+$(safe "$br")"
    }

    resolve_branch_path() {
      local br="$1"
      local path
      path="$(find_wt_by_branch "$br" || true)"
      if [ -n "$path" ]; then
        echo "$path"
      else
        echo "$(default_wt_path_for_branch "$br")"
      fi
    }

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || err "not a git repo"
  '';
in
{
  programs.gitExtend.commands = [
    {
      path = [
        "worktree"
        "checkout"
      ];
      help = "Checkout a branch into a sibling worktree and cd into it.";
      command = helpers + ''

        if [[ ''${1:-} == "-b" ]]; then
          shift
          br="''${1:-}"
          [ -n "$br" ] || err "usage: git worktree checkout -b <branch> [<start>]"
          start="''${2:-}"
          dest="$(default_wt_path_for_branch "$br")"
          if [ -n "$start" ]; then
            git worktree add -b "$br" "$dest" "$start"
          else
            git worktree add -b "$br" "$dest"
          fi
        else
          br="''${1:-}"
          [ -n "$br" ] || err "usage: git worktree checkout <branch>"
          if git show-ref --verify --quiet "refs/heads/$br"; then
            dest="$(find_wt_by_branch "$br" || true)"
            if [ -z "$dest" ]; then
              dest="$(default_wt_path_for_branch "$br")"
              git worktree add "$dest" "$br"
            fi
          elif git show-ref --verify --quiet "refs/remotes/origin/$br"; then
            dest="$(default_wt_path_for_branch "$br")"
            git worktree add --track -b "$br" "$dest" "origin/$br"
          else
            err "branch not found: $br"
          fi
        fi

        echo "$dest"
        if [ -n "''${SHELL_CD_REQUEST_FILE-}" ] && [ -d "$dest" ]; then
          printf '%s\n' "$dest" >"$SHELL_CD_REQUEST_FILE"
        fi
      '';
    }
    {
      path = [
        "worktree"
        "delete"
      ];
      help = "Remove a worktree by branch or path; -b also deletes the branch.";
      command = helpers + ''

        force_flag=""
        del_branch=""
        target=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -f | --force) force_flag="--force"; shift ;;
            -b) del_branch=1; shift ;;
            -*) err "unknown option: $1" ;;
            *) target="$1"; shift ;;
          esac
        done

        [ -n "$target" ] || err "usage: git worktree delete [-f|--force] [-b] <branch|path>"

        if [ -d "$target" ]; then
          path="$target"
        else
          path="$(resolve_branch_path "$target")"
        fi

        br=""
        [ -n "$del_branch" ] && br="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || true)"

        if [ -n "$force_flag" ]; then
          git worktree remove "$force_flag" "$path"
        else
          git worktree remove "$path"
        fi

        [ -n "$del_branch" ] && [ -n "$br" ] && git branch -D "$br"
      '';
    }
    {
      path = [
        "worktree"
        "fix"
      ];
      help = "Repair worktree admin files for a branch.";
      command = helpers + ''

        br="''${1:-}"
        [ -n "$br" ] || err "usage: git worktree fix <branch>"
        path="$(resolve_branch_path "$br")"
        git worktree repair "$path"
      '';
    }
    {
      path = [
        "worktree"
        "clean"
      ];
      help = "Remove worktrees whose branch upstream is gone.";
      command = helpers + ''

        [ "$#" -eq 0 ] || err "usage: git worktree clean"

        git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads |
          awk '$2 == "[gone]" { print $1 }' |
          while IFS= read -r br; do
            path="$(find_wt_by_branch "$br" || true)"
            [ -n "$path" ] || continue
            if git worktree remove "$path" 2>/dev/null; then
              echo "removed: $path"
            else
              echo "skipped: $path" >&2
            fi
          done
      '';
    }
    {
      path = [
        "worktree"
        "pr"
      ];
      help = "Checkout a PR into a sibling worktree and cd into it.";
      command = helpers + ''

        num="''${1:-}"
        [ -n "$num" ] || err "usage: git worktree pr <number>"
        br="$(gh pr view "$num" --json headRefName -q .headRefName)"
        [ -n "$br" ] || err "could not resolve PR #$num"

        dest="$(find_wt_by_branch "$br" || true)"
        if [ -z "$dest" ]; then
          dest="$(default_wt_path_for_branch "$br")"
          git worktree add --detach "$dest"
          (cd "$dest" && PATH="${pkgs.git}/bin:$PATH" gh pr checkout "$num") || {
            git worktree remove --force "$dest"
            exit 1
          }
        fi

        echo "$dest"
        if [ -n "''${SHELL_CD_REQUEST_FILE-}" ] && [ -d "$dest" ]; then
          printf '%s\n' "$dest" >"$SHELL_CD_REQUEST_FILE"
        fi
      '';
    }
  ];

  home.shellAliases = {
    gw = "git worktree";
  };
}
