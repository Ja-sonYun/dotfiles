
export PATH="$PATH:$MYDOTFILES/scripts"
export PATH="$PATH:$HOME/.bin"
export PATH="$PATH/.local/bin"
export KITTY_CONFIG_DIRECTORY="$MYDOTFILES/"
export XDG_CONFIG_HOME="$MYDOTFILES"
export ZSH="$HOME/.oh-my-zsh"

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
export PATH="$PYENV_ROOT/shims:$PATH"

export EDITOR="`which nvim`"

if [[ `uname` == "Darwin" ]]; then
    source $MYDOTFILES/zsh/module/homebrew.sh
    export OS_ENV=m1
    export PATH="$MYDOTFILES/bin/m1:$PATH"
elif [[ `uname` == "Linux" ]]; then
    export OS_ENV=wsl
    export PATH="$MYDOTFILES/bin/wsl:$PATH"
fi

export PATH="$MYDOTFILES/scripts:$PATH"

export KEY_FILE_PATH="$MYDOTFILES/.key"
export CREDENTIAL_MANAGER_PATH="$MYDOTFILES/credential/credential-manager"
export ENCRYPT_LOCK="$MYDOTFILES/.encrypted"
