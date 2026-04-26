#!/bin/bash

export NVM_DIR="$HOME/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
. "$NVM_DIR/nvm.sh"
nvm install 24

# Symlink into /usr/local/bin so opencode (non-login shell) can find them
NODE_BIN="$(nvm which 24 | xargs dirname)"
sudo ln -sf "$NODE_BIN/node" /usr/local/bin/node
sudo ln -sf "$NODE_BIN/npm"  /usr/local/bin/npm
sudo ln -sf "$NODE_BIN/npx"  /usr/local/bin/npx
