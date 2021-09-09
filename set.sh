#/bin/sh

# PARAMETER
# - $1 : file destination
# - $2 : source file
link_file () {
    if [ -f "$1" ]; then
        # backup
        old_file="$1""_old"
        # remove old file if exists
        if [ -f "$old_file" ]; then
            rm $old_file
        fi
        mv $1 "$1""_old"
    fi
    ln -s $2 $1
}

# link dotfiles
link_file $HOME/.zshrc $MYDOTFILES/zsh/zshrc
link_file $HOME/.tmux.conf $MYDOTFILES/zsh/tmux.conf

# decrypt secret files if they're encrypted
if [ -f "$MYDOTFILES/.encrypted" ]; then
    credential_manager -d
fi

# install dependencies
if [ "$1" = "install" ]; then
    echo " - install dependencies."
    sudo npm i -g pyright
    sudo npm i -g typescript-language-server
fi
