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

    main_worktree_path() {
      local root
      root="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
      [ -n "$root" ] || err "could not find main worktree"
      echo "$root"
    }

    repo_paths() {
      local root parent base
      root="$(main_worktree_path)"
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

    copy_env_files() {
      local source_root="$1"
      local dest="$2"
      local rel base source target

      git -C "$source_root" ls-files --others -z |
        while IFS= read -r -d "" rel; do
          base="''${rel##*/}"
          case "$base" in
            .env | .envrc) ;;
            *) continue ;;
          esac

          source="$source_root/$rel"
          target="$dest/$rel"

          if [ -L "$source" ]; then
            echo "skipped symlink: $rel" >&2
            continue
          fi
          [ -f "$source" ] || continue
          if [ -e "$target" ] || [ -L "$target" ]; then
            echo "skipped existing: $rel" >&2
            continue
          fi

          mkdir -p "$(dirname "$target")" || return 1
          cp -p "$source" "$target" || return 1
        done
    }

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || err "not a git repo"
  '';
  renameCommand = flag: {
    path = [ "branch" ];
    inherit flag;
    help = "Rename the current linked-worktree branch and directory.";
    command = helpers + ''

      if [ "$#" -ne 1 ]; then
        git branch ${flag} "$@"
        exit $?
      fi

      git_dir="$(git rev-parse --absolute-git-dir)"
      common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
      if [ "$git_dir" = "$common_dir" ]; then
        git branch ${flag} "$@"
        exit $?
      fi

      new_br="$1"
      old_br="$(git branch --show-current)"
      [ -n "$old_br" ] || err "detached HEAD"
      git check-ref-format --branch "$new_br" >/dev/null
      if git show-ref --verify --quiet "refs/heads/$new_br"; then
        err "branch already exists: $new_br"
      fi

      current_path="$(git rev-parse --show-toplevel)"
      dest="$(default_wt_path_for_branch "$new_br")"
      if [ "$current_path" = "$dest" ]; then
        git branch ${flag} "$new_br"
        if [ -n "''${SHELL_CD_REQUEST_FILE-}" ]; then
          printf '%s\n' "$dest" >"$SHELL_CD_REQUEST_FILE"
        fi
        exit 0
      fi
      if [ -e "$dest" ] || [ -L "$dest" ]; then
        err "worktree path already exists: $dest"
      fi

      git worktree move "$current_path" "$dest"
      if ! git -C "$dest" branch ${flag} "$new_br"; then
        git -C "$dest" worktree move "$dest" "$current_path" ||
          echo "error: failed to restore worktree path: $current_path" >&2
        exit 1
      fi

      if [ -n "''${SHELL_CD_REQUEST_FILE-}" ]; then
        printf '%s\n' "$dest" >"$SHELL_CD_REQUEST_FILE"
      fi
    '';
  };
in
{
  programs.gitExtend.commands = [
    (renameCommand "-m")
    (renameCommand "--move")
    {
      path = [
        "worktree"
        "checkout"
      ];
      help = "Checkout a branch into a sibling worktree and cd into it.";
      command = helpers + ''

        created=""
        created_branch=""
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
          created=1
          created_branch=1
        else
          br="''${1:-}"
          [ -n "$br" ] || err "usage: git worktree checkout <branch>"
          if git show-ref --verify --quiet "refs/heads/$br"; then
            dest="$(find_wt_by_branch "$br" || true)"
            if [ -z "$dest" ]; then
              dest="$(default_wt_path_for_branch "$br")"
              git worktree add "$dest" "$br"
              created=1
            fi
          elif git show-ref --verify --quiet "refs/remotes/origin/$br"; then
            dest="$(default_wt_path_for_branch "$br")"
            git worktree add --track -b "$br" "$dest" "origin/$br"
            created=1
            created_branch=1
          else
            err "branch not found: $br"
          fi
        fi

        if [ -n "$created" ] && ! copy_env_files "$(main_worktree_path)" "$dest"; then
          git worktree remove --force "$dest" || err "failed to remove incomplete worktree: $dest"
          if [ -n "$created_branch" ]; then
            git branch -D "$br" || err "failed to remove incomplete branch: $br"
          fi
          err "failed to copy environment files"
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
