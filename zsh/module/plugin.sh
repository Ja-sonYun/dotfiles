export ZPLUG_HOME=~/.zplug

if [[ ! -f $ZPLUG_HOME/init.zsh ]]; then
    git clone https://github.com/zplug/zplug $ZPLUG_HOME
fi
source $ZPLUG_HOME/init.zsh

export ZSH=$ZPLUG_HOME/repos/robbyrussell/oh-my-zsh

zplug "zsh-users/zsh-completions"
zplug "zsh-users/zsh-syntax-highlighting"
zplug "zsh-users/zsh-autosuggestions"
zplug "zsh-users/zsh-history-substring-search"
zplug "plugins/colorize", from:oh-my-zsh
zplug "plugins/zsh_reload", from:oh-my-zsh
zplug "plugins/brew", from:oh-my-zsh
zplug "plugins/brew-cask", from:oh-my-zsh
zplug "plugins/tmux", from:oh-my-zsh
zplug "plugins/tmuxinator", from:oh-my-zsh

if [[ `uname` == "Darwin" ]]; then
    zplug "plugins/osx", from:oh-my-zsh, if:"[[ $OSTYPE == *darwin* ]]"
fi

zplug "djui/alias-tips", from:github
zplug "Aloxaf/fzf-tab", from:github

zplug "junegunn/fzf-bin", \
    from:gh-r, \
    as:command, \
    rename-to:fzf, \
    use:"*darwin*amd64*"

zplug "plugins/git",   from:oh-my-zsh
zplug "Seinh/git-prune", from:github

zplug "robbyrussell/oh-my-zsh", use:"lib/*.zsh", defer:2

# theme
zplug "lib/spectrum", from:oh-my-zsh
zplug "lib/theme-and-appearance", from:oh-my-zsh
zplug "romkatv/powerlevel10k", use:powerlevel10k.zsh-theme, from:github, as:theme

if ! zplug check --verbose; then
    printf "Install? [y/N]: "
    if read -q; then
        echo; zplug install
    fi
fi

zplug load
