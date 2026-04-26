# opencode-sandbox

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Docker](https://img.shields.io/badge/docker-ready-blue)
![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macOS-lightgrey)

A lightweight, open-source sandbox to run **opencode** securely inside Docker on Linux and macOS.
---

## [*] Overview

`opencode-sandbox` provides an isolated environment for running opencode in a controlled and reproducible way. By leveraging Docker, all execution happens inside a sandbox, minimizing risks to your host system.

The project runs opencode inside a Docker container with the opencode config directory mapped from the host.

---

## [*] Quick Start

```bash
# get this repo
git clone https://github.com/r4stl1n/opencode-sandbox

# build image locally
docker build -t opencode-sandbox .

# run it to try it out
docker run --rm -it opencode-sandbox
```
Now associate the script with an alias in the `.profile, .bashrc, .zshrc, etc` file.

```bash
alias ocsandbox="bash <this local repo>/opencode-sandbox.sh"
```

To reuse the same .config/opencode use the following alias
```bash
alias ocsandbox='OPENCODE_SANDBOX_HOME=~/.config/opencode bash <this local repo>/opencode-sandbox.sh'
```

Now you can run `ocsandbox` (or another alias name) in your project directory.

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
ocsandbox help
```

#### Bash Mode
Start a bash terminal in your container:
```bash
ocsandbox bash
```
It can be useful for:
- Installing tools (node, python) with `asdf` or `sudo apt install`
- Setting up your git (or copying your host .gitconfig to .opencode_sandbox_home/)
- Manually running a server, or debugging
- Manual configuration

#### Update
Update opencode inside the container:
```bash
ocsandbox update
```

#### Destroy
Stop and remove the sandbox container for the current folder. Each folder
gets its own container (named after the folder + a short hash of its path),
so `destroy` only affects the sandbox tied to the directory you run it in —
sandboxes for other folders are left untouched. The container is also
stopped automatically when you exit an `ocsandbox` session; `destroy` is
for when you want to fully remove it (e.g. to recreate it with different
ports or a clean state):
```bash
ocsandbox destroy
```

---

## [*] Persistent Config

The default directory for the persistent opencode config is `~/.opencode_sandbox_home`. Instead of bind-mounting the whole directory into the container's `/opencode/.config/opencode`, only a fixed allowlist of items is mounted (each one only if it exists on the host):

- `opencode.json`
- `AGENTS.md`
- `skills/`
- `tools/`
- `install.sh` (see [Install Hook](#-install-hook))

Anything else opencode writes under its config dir at runtime — most notably the plugin runtime install (`node_modules`, `package.json`, `package-lock.json`, `bun.lock` for `@opencode-ai/plugin`) — stays inside the container and does **not** leak back onto the host. Anything else inside the container (installed tools, shell history, etc.) is also **not** persisted — it lives only for the lifetime of the container.

To reset the config, just delete it: `rm -r ~/.opencode_sandbox_home`

You can point at a different host directory with the `OPENCODE_SANDBOX_HOME` variable:
```bash
alias ocsandbox="OPENCODE_SANDBOX_HOME=/your/custom/opencode_sandbox_home  bash <this local repo>/opencode-sandbox.sh"
```

### Install Hook

If `install.sh` exists at the root of `OPENCODE_SANDBOX_HOME`, it is executed inside the container the first time the container is created. Use it as a one-time provisioning hook — for example to `apt-get install` extra tools or set up language runtimes via `asdf` — without rebuilding the Docker image.

An example is provided in this repo at `install.sh.ex`, which installs Node.js via `nvm` and symlinks `node`/`npm`/`npx` into `/usr/local/bin` so opencode can find them. Copy it to `~/.opencode_sandbox_home/install.sh` (and `chmod +x`) to use it as a starting point.

---

## [*] Default Model
opencode reads its config from `~/.opencode_sandbox_home/opencode.json` (the host directory, mounted at `/opencode/.config/opencode` inside the container). Set the default model via the top-level `"model"` field, formatted as `"<provider>/<model-id>"`:

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
alias ocsandbox="OPENCODE_SANDBOX_ALLOWED_DIR=~/MyProjects  bash <this local repo>/opencode-sandbox.sh"
```

This also prevents you from running opencode unintentionally in other directories.

---

## Variables 

Script variables:
- `OPENCODE_SANDBOX_HOME` - host directory holding opencode config items (`opencode.json`, `AGENTS.md`, `skills/`, `tools/`, `install.sh`); only those allowlisted items are bind-mounted into `/opencode/.config/opencode`, so opencode's runtime plugin install stays container-internal
- `OPENCODE_SANDBOX_ALLOWED_DIR` - your projects workspace/directory
- `OPENCODE_SANDBOX_IMAGE_DOCKER` - custom image for docker
- `OPENCODE_SANDBOX_CONTAINER_NAME` - set a container name (by default, it is 'opencode' with a hash of your workspace directory)
- `OPENCODE_PORT` - port exposed by the container (default: `4096`). On macOS this is published as `127.0.0.1:<port>:<port>`; on Linux the container runs with `--network host`.
- `OPENCODE_SANDBOX_PORTS` - comma-separated extra ports to publish (e.g. `OPENCODE_SANDBOX_PORTS="3000,5173"`) for things like web dev servers. Each port is published as `127.0.0.1:<port>:<port>`. Ports are baked in at container creation, so changing them requires `ocsandbox destroy` and a re-run.

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
