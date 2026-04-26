#!/bin/bash

# nvm's installer appends its loader to ~/.bashrc. The Dockerfile sets
# BASH_ENV=/opencode/.bashrc and ships a non-interactive-friendly bashrc, so
# opencode's `bash -c` shell-outs will pick up node/npm/npx automatically —
# no symlinks into /usr/local/bin needed.
export NVM_DIR="$HOME/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
. "$NVM_DIR/nvm.sh"
nvm install 24
