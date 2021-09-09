if [ -e /opt/homebrew ]; then
    HOMEBREW_ROOT=/opt/homebrew
else
    HOMEBREW_ROOT=/usr/local
fi
export HOMEBREW_ROOT
eval $(${HOMEBREW_ROOT}/bin/brew shellenv)
