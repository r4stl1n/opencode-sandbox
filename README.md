# opencode-sandbox

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Docker](https://img.shields.io/badge/docker-ready-blue)
![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macOS-lightgrey)

A lightweight, open-source sandbox to run **opencode** securely inside Docker on Linux and macOS.
---

## [*] Overview

`opencode-sandbox` provides an isolated environment for running opencode in a controlled and reproducible way. All execution happens inside a Docker container, minimizing risk to your host system.

Everything the sandbox needs lives **inside this repo**: the image, the proxy config, the workspace folder you customize. No `~/.config/opencode`, no `~/.opencode_sandbox_home`, no other host-side state — just clone, configure, and run.

### What gets mounted / baked

| Source (host side) | Destination (container) | When |
|---|---|---|
| `defaults/opencode.json` | `/opencode/.config/opencode/opencode.json` | baked at `docker build` |
| `workspace/AGENTS.md` | `/opencode/.config/opencode/AGENTS.md` (read-only) | mounted if present |
| `workspace/skills/` | `/opencode/.config/opencode/skills/` | mounted if present |
| `workspace/tools/` | `/opencode/.config/opencode/tools/` | mounted if present |
| `workspace/install.sh` | `/opencode/.config/opencode/install.sh` (read-only, auto-run once) | mounted if present |
| `.env` | proxy container only — never the sandbox | loaded by `docker compose` |
| your CWD (or `OPENCODE_SANDBOX_ALLOWED_DIR`) | same path inside the container | mounted at sandbox start |

That's the complete list of host inputs. Anything else opencode writes at runtime (plugin install, shell history, installed packages) lives only inside the container.

---

## [*] Quick Start

```bash
# 1. Get this repo
git clone https://github.com/r4stl1n/opencode-sandbox
cd opencode-sandbox

# 2. Configure the LLM proxy with your real API keys
cp .env.example .env
$EDITOR .env   # set ANTHROPIC_API_KEY and/or OPENAI_API_KEY

# 3. (Optional) Drop your AGENTS.md, skills/, tools/, install.sh into workspace/

# 4. Build the sandbox image
docker build -t opencode-sandbox .
```

Now associate the script with an alias in your `.profile`, `.bashrc`, `.zshrc`, etc:

```bash
alias ocsandbox="bash <this local repo>/opencode-sandbox.sh"
```

Then run `ocsandbox` from any project directory. The first invocation auto-starts the LLM proxy and creates a per-project sandbox container.

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
- Setting up your git
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

## [*] The `workspace/` Folder

User-side opencode config lives in the repo-local `workspace/` folder, next to `opencode-sandbox.sh`. The script's allowlist (see the table at the top) decides which items get bind-mounted into `/opencode/.config/opencode/` — anything else you drop into `workspace/` is ignored.

`opencode.json` is intentionally **not** in that allowlist. It's baked into the image at build time from `defaults/opencode.json` so opencode always routes through the LLM proxy. To change the default model or add providers, edit `defaults/opencode.json` and rebuild the image (`docker build -t opencode-sandbox .`).

### Install hook

`workspace/install.sh`, if present, is executed inside the container the first time the container is created. Use it as a one-time provisioning hook — `apt-get install` extra tools, set up language runtimes via `asdf`, etc. — without rebuilding the Docker image.

A starting example is provided at `install.sh.ex` in the repo root (installs Node.js via `nvm` and symlinks `node`/`npm`/`npx` into `/usr/local/bin`). Copy it into the workspace and mark it executable:

```bash
cp install.sh.ex workspace/install.sh
chmod +x workspace/install.sh
```

---

## [*] LLM Proxy

The sandbox always routes LLM traffic through a small long-lived **proxy container** (`opencode-sandbox-proxy`) that holds your real provider API keys. The sandbox container only ever sees a placeholder key (the literal string `sandbox`), so a jailbroken agent inside it has no real key to leak.

The proxy auto-starts on the first `ocsandbox` invocation, and the sandbox container is attached to its Docker network so the proxy is reachable at `http://opencode-sandbox-proxy:4000`.

### Setup

```bash
cp .env.example .env
$EDITOR .env   # add ANTHROPIC_API_KEY and/or OPENAI_API_KEY (and optionally OPENAI_COMPAT_*)
```

`.env` is gitignored. Keys are read **only** by the proxy container — they never enter the sandbox container or your shell environment.

### How it's wired

- The baked `defaults/opencode.json` (inside the image) points opencode's `anthropic` and `openai` providers at the proxy.
- The script also injects `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `ANTHROPIC_API_KEY=sandbox`, `OPENAI_API_KEY=sandbox` into the container, so any other SDK that respects those env vars (e.g. the `claude` SDK, the official `openai` SDK) is auto-routed too.
- To customize the default model or add providers, edit `defaults/opencode.json` and rebuild the image.

### Routes

| Route | Forwards to | Auth header swapped |
|---|---|---|
| `/anthropic/{path}` | `ANTHROPIC_UPSTREAM` (default `https://api.anthropic.com`) | `x-api-key` |
| `/v1/{path}` | `OPENAI_UPSTREAM` (default `https://api.openai.com`) | `Authorization: Bearer …` |
| `/compat/{path}` | `OPENAI_COMPAT_UPSTREAM` (no default) | `Authorization: Bearer …` |

The `/compat` route is for arbitrary OpenAI-compatible upstreams — LM Studio, Ollama, OpenRouter, vLLM, etc. It's only enabled when you set `OPENAI_COMPAT_UPSTREAM`.

### Managing the proxy

```bash
ocsandbox proxy up      # start (auto-runs on first ocsandbox invocation too)
ocsandbox proxy down    # stop and remove
ocsandbox proxy logs    # follow logs
ocsandbox proxy status  # show running state
```

To skip the proxy entirely (no auto-start, no network attach, no env injection), set `OPENCODE_SANDBOX_PROXY=0`.

---

## Allowed Project Directories

> Note: this is *project* scoping, not the `workspace/` folder. By default each project directory gets its own sandbox container.

You can share one container across multiple projects under a parent directory (e.g. `~/MyProjects`) by setting `OPENCODE_SANDBOX_ALLOWED_DIR` in your alias:

```bash
alias ocsandbox="OPENCODE_SANDBOX_ALLOWED_DIR=~/MyProjects bash <this local repo>/opencode-sandbox.sh"
```

This also prevents you from accidentally launching opencode in directories outside that root.

---

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `OPENCODE_SANDBOX_ALLOWED_DIR` | current dir | Host root from which `ocsandbox` may launch a sandbox; also bind-mounted into the container at the same path. |
| `OPENCODE_SANDBOX_IMAGE_DOCKER` | `opencode-sandbox` | Sandbox image tag. |
| `OPENCODE_SANDBOX_CONTAINER_NAME` | `ocsandbox-<dir>-<hash>` | Override the auto-generated per-project container name. |
| `OPENCODE_PORT` | random high port (49152–65535) | Primary port published as `127.0.0.1:<port>:<port>` on every platform (always bridge networking — no `--network host`). |
| `OPENCODE_SANDBOX_PORTS` | _unset_ | Comma-separated extra ports to publish (e.g. `3000,5173`). Baked in at container creation — changing them requires `ocsandbox destroy` and a re-run. |
| `OPENCODE_SANDBOX_PROXY` | `1` | Set to `0` to disable LLM proxy plumbing entirely (no auto-start, no network attach, no env injection). |

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
