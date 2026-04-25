# opencode-sandbox

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Docker](https://img.shields.io/badge/docker-ready-blue)
![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macOS-lightgrey)

A lightweight, open-source sandbox to run **opencode** securely inside Docker on Linux and macOS.
---

## [*] Overview

`opencode-sandbox` provides an isolated environment for running opencode in a controlled and reproducible way. By leveraging Docker, all execution happens inside a sandbox, minimizing risks to your host system.

The project runs opencode inside a Docker container with a mapped home directory.

---

## [*] Quick Start

```bash
# get this repo
git clone https://github.com/arezi/opencode-sandbox.git

# build image locally
docker build -t opencode-sandbox .

# run it to try it out
docker run --rm -it opencode-sandbox
```


Or run by saving state (opencode configs) in your real project.

```bash
cd <my-project-directory>

docker run --rm -it 
  -v ~/.opencode_sandbox_home:/opencode \
  -v "$(pwd):$(pwd)" --workdir "$(pwd)" \
  opencode-sandbox
```

The `docker run --rm` is not a good option for real use. However, the `opencode-sandbox.sh` script is available, which manages the container instance and allows configuring environments.

It can be associated with an alias in the `.profile` file.

```bash
alias opencode="bash <this local repo>/opencode-sandbox.sh"
```

Now you can run `opencode` (or another alias name) in your project directory.


---

## [*] Motivation

While solutions like Docker Sandboxes exist, they typically require **Docker Desktop**.

This is a problem for users who:

- Prefer native Docker Engine
- Avoid heavy GUI-based tooling
- Want full control over their environment

`opencode-sandbox` is designed to be:

- [*] Lightweight
- [*] Linux & macOS friendly
- [*] CLI-native
- [*] Security-focused

No Docker Desktop required — just plain Docker.

---

## [*] Why Sandbox AI Tools?

AI tools may:

- Execute generated code
- Install dependencies
- Modify files

Without isolation, this can lead to:

- [!] File corruption or deletion
- [!] Execution of unsafe code
- [!] Polluted development environments

Using Docker sandboxing ensures:

- [+] Host system protection
- [+] Isolated execution
- [+] Reproducible environments


---

### Special Parameters

After you have created the alias for the script, you can use special parameters:

#### Help
Show the list of available commands:
```bash
opencode help
```

#### Bash Mode
Start a bash terminal in your container:
```bash
opencode bash
```
It can be useful for:
- Installing tools (node, python) with `asdf` or `sudo apt install`
- Setting up your git (or copying your host .gitconfig to .opencode_sandbox_home/)
- Manually running a server, or debugging
- Manual configuration

#### Update
Update opencode inside the container:
```bash
opencode update
```

#### Stop
Stop and remove the sandbox container:
```bash
opencode stop
```


---

## [*] Installing tools

You can prompt opencode to "install nodejs 22 with asdf".

Or inside the container:

```bash
## example: install nodejs
asdf plugin add nodejs       # add nodejs plugin
asdf list all nodejs 24      # list all sub-versions of nodejs 24 
asdf latest nodejs 24        # get latest version of 24
asdf install nodejs 24.14.1  # install a specific version
asdf set nodejs 24.14.1      # set a specific version for the current project
asdf set -u nodejs 24.14.1   # set a specific version as the default for the user
```

You can install Node.js, Python, Java, mvn, or more than 800 [plugins](https://github.com/asdf-vm/asdf-plugins?tab=readme-ov-file#plugin-list)

```bash
asdf plugin list all         # list all plugins
```

---

## [*] Persistent Home

The default directory for the persistent home is `~/.opencode_sandbox_home`

Stores:

- opencode config and Sessions
- Installed tools
- Configurations

To reset the environment, just delete it: `rm -r ~/.opencode_sandbox_home`

You can configure a specific home directory for your alias with the `OPENCODE_SANDBOX_HOME` variable. For example:
```bash
alias opencode="OPENCODE_SANDBOX_HOME=/your/custom/opencode_sandbox_home  bash <this local repo>/opencode-sandbox.sh"
```

---

## [*] Default Model
opencode reads its config from `~/.opencode_sandbox_home/.config/opencode/opencode.json` (the sandbox home, mounted at `/opencode` inside the container). Set the default model via the top-level `"model"` field, formatted as `"<provider>/<model-id>"`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-4-6"
}
```

The provider key must match either a built-in opencode provider or a custom one defined under `"provider"` in the same file. Changes take effect on the next opencode session — no container rebuild needed.

---

## Allowed Project Directories

By default, one Docker instance is created per project directory. However, you can use the same Docker instance for a workspace with multiple projects (e.g., `~/MyProjects`). You can configure this in your alias.

```bash
alias opencode="OPENCODE_SANDBOX_ALLOWED_DIR=~/MyProjects  bash <this local repo>/opencode-sandbox.sh"
```

This also prevents you from running opencode unintentionally in other directories.


---

## Variables 

Script variables:
- `OPENCODE_SANDBOX_HOME` - home persistence directory 
- `OPENCODE_SANDBOX_ALLOWED_DIR` - your projects workspace/directory
- `OPENCODE_SANDBOX_IMAGE_DOCKER` - custom image for docker
- `OPENCODE_SANDBOX_CONTAINER_NAME` - set a container name (by default, it is 'opencode' with a hash of your workspace directory)
- `OPENCODE_PORT` - port exposed by the container (default: `4096`). On macOS this is published as `127.0.0.1:<port>:<port>`; on Linux the container runs with `--network host`.


---

## Limitations

Currently, some features are not supported:
- `/voice` command

---

## [*] Contributing
PRs and issues are welcome!
---

## [*] License
MIT License
