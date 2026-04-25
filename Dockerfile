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

# install asdf
RUN curl -fsSL https://github.com/asdf-vm/asdf/releases/download/v0.19.0/asdf-v0.19.0-linux-amd64.tar.gz -o asdf.tar.gz  && \
    tar zxvf asdf.tar.gz && rm -f tar zxvf asdf.tar.gz && chmod +x asdf && mv asdf /usr/local/bin/ 

RUN mkdir -p /asdf && chown -R opencode:opencode /asdf

ENV ASDF_DATA_DIR="/asdf"
ENV PATH="${ASDF_DATA_DIR}/shims:/opencode/.local/bin:/opencode/.opencode/bin:${PATH}"

# install opencode and move to bin system
RUN curl -fsSL https://opencode.ai/install | bash   && \
    mv /root/.opencode/bin/opencode /usr/local/bin/

USER opencode

# init, by default
CMD ["opencode"]
