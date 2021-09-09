#/bin/sh

# PARAMETER
# - $1 : file destination
# - $2 : source file
link_file () {
    if [ -f "$1" ]; then
        echo "[*] $1 exist. please remove it manually."
    else
        echo "[+] $1 -> $2"
        ln -s $2 $1
    fi
}

# link dotfiles
link_file $HOME/.zshrc $MYDOTFILES/zsh/zshrc
link_file $HOME/.tmux.conf $MYDOTFILES/tmux/tmux.conf

# decrypt secret files if they're encrypted
if [ -f "$MYDOTFILES/.encrypted" ]; then
    credential_manager -d
    credential_manager -e
    git add "**/*_encrypted"
    git commit -m "[script] auto encryption"
    git push
fi

# install dependencies
if [ "$1" = "install" ]; then
    echo " - install dependencies."
    sudo npm i -g pyright
    sudo npm i -g typescript-language-server
fi
