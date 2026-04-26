FROM ubuntu:latest

# opencode envs
ENV BUN_RUNTIME_TRANSPILER_CACHE_PATH=0
#ENV OPENCODE_HOSTNAME=0.0.0.0
#ENV OPENCODE_HOST=0.0.0.0
#ENV OPENCODE_PORT=4096

# install dependencies 
#   (utils)
#   (editors)
#   gawk gpg - asdf dependencies
#   sudo - for allow opencode to install packages
#   git - for opencode to manager repository
#   libatomic1 - need to nodejs
RUN apt-get update && apt-get install -y \
    curl ca-certificates lsb-release wget zip unzip \
    nano vim jq \
    gawk gpg \
    sudo \
    git \
    libatomic1 \
    && rm -rf /var/lib/apt/lists/*

# create a user opencode with uid/gid 1001, which is what is normally used for users on the host machine.
RUN groupadd -g 1001 opencode && \
    useradd -u 1001 -g opencode -m -d /opencode -s /bin/bash opencode

# opencode shells out via non-interactive `bash -c`. BASH_ENV makes those
# invocations source ~/.bashrc so anything install.sh sets up (nvm/node, pyenv,
# rbenv, custom PATH, etc.) is visible without per-tool symlinks into
# /usr/local/bin.
ENV BASH_ENV=/opencode/.bashrc

# Replace the default ~/.bashrc with one that does NOT short-circuit for
# non-interactive shells, so nvm's loader (appended by `nvm install`) runs for
# opencode's `bash -c` invocations too. Keep the rest of the user's defaults.
RUN printf '%s\n' \
    '# opencode-sandbox: non-interactive friendly bashrc.' \
    '# The default Ubuntu skeleton returns early for non-interactive shells,' \
    '# which breaks opencode tooling that expects nvm/pyenv/etc. on PATH.' \
    'export PATH="$HOME/.local/bin:$PATH"' \
    > /opencode/.bashrc && chown opencode:opencode /opencode/.bashrc

# allow opencode work and mount (as volumes) workspace/projects dirs
RUN mkdir -p /workspace && chown -R opencode:opencode /workspace

# Pre-create the config dir owned by opencode so that bind-mounting individual
# config files into it (rather than the whole dir) doesn't leave the parent
# owned by root and unwritable for opencode's own plugin install.
RUN mkdir -p /opencode/.config/opencode && chown -R opencode:opencode /opencode/.config

# set default workspace
WORKDIR /workspace

# allow user 'opencode' run anything in container with sudo
RUN echo "opencode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/opencode && \
    chmod 0440 /etc/sudoers.d/opencode

# copy utils
COPY --chmod=0755 utils/place_in_var.sh  /usr/local/bin/place_in_var
RUN mkdir -p /var/usr && chown -R opencode:opencode /var/usr

# install opencode and move to bin system
RUN curl -fsSL https://opencode.ai/install | bash   && \
    mv /root/.opencode/bin/opencode /usr/local/bin/

USER opencode

# init, by default
CMD ["opencode"]
