#!/usr/bin/env bash
#
# opencode-sandbox: run opencode inside a per-project Docker sandbox, with an
# optional long-lived LLM proxy that holds the real provider API keys.
#
# Sections:
#   1. Configuration       — all defaults / env-var driven settings
#   2. Helpers             — pure functions, no side effects on globals
#   3. Builders            — populate global *_ARGS arrays for `docker run`
#   4. Lifecycle           — proxy and sandbox container lifecycle
#   5. Subcommands         — help, proxy, destroy, update, default

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sandbox image. Override with OPENCODE_SANDBOX_IMAGE_DOCKER.
OPENCODE_SANDBOX_IMAGE_DOCKER=${OPENCODE_SANDBOX_IMAGE_DOCKER:-opencode-sandbox}

# Repo-local workspace folder bind-mounted into the sandbox config dir.
# `opencode.json` is intentionally NOT in this list — it's baked into the
# image from defaults/opencode.json so opencode always routes through the proxy.
WORKSPACE_DIR="$SCRIPT_DIR/workspace"
SYNCED_CONFIG_ITEMS=("AGENTS.md" "skills" "tools" "install.sh")
# Items the agent should never write back to the host. install.sh in particular
# is auto-executed on container creation, so editability would be a persistence
# vector.
SYNCED_CONFIG_ITEMS_READONLY=("AGENTS.md" "install.sh")

# LLM proxy plumbing. The proxy holds the real provider API keys; the sandbox
# only ever sees the placeholder string "sandbox". Set OPENCODE_SANDBOX_PROXY=0
# to skip starting / attaching to it.
PROXY_ENABLED=${OPENCODE_SANDBOX_PROXY:-1}
PROXY_NETWORK="opencode-sandbox-proxy"
PROXY_CONTAINER="opencode-sandbox-proxy"
PROXY_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------

print_help() {
   cat <<'EOF'
opencode sandbox for docker.
Usage: ocsandbox [command] [args]

Commands:
  help                          Show this help message.
  bash                          Start a bash session inside the container.
  destroy                       Stop and remove the sandbox container.
  update                        Update opencode inside the container.
  proxy [up|down|logs|status]   Manage the LLM proxy (default: status).
  (none)                        Run 'opencode' inside the container.

Environment:
  OPENCODE_SANDBOX_ALLOWED_DIR  Restrict which host dir(s) can launch a sandbox.
  OPENCODE_SANDBOX_IMAGE_DOCKER Override the sandbox image (default: opencode-sandbox).
  OPENCODE_SANDBOX_CONTAINER_NAME
                                Override the auto-generated container name.
  OPENCODE_PORT                 Primary opencode port (default: random high port).
  OPENCODE_SANDBOX_PORTS        Comma-separated extra ports to publish.
  OPENCODE_SANDBOX_PROXY        Set to 0 to disable LLM proxy plumbing (default: 1).
EOF
}

# Detect local timezone in a portable way (timedatectl is Linux-only).
detect_tz() {
   if [[ -n "${TZ:-}" ]]; then echo "$TZ"; return; fi
   if [[ -L /etc/localtime ]]; then
      local link
      link=$(readlink /etc/localtime 2>/dev/null)
      case "$link" in
         */zoneinfo/*) echo "${link##*/zoneinfo/}"; return ;;
      esac
   fi
   if [[ -r /etc/timezone ]]; then cat /etc/timezone; return; fi
   if command -v timedatectl >/dev/null 2>&1; then
      timedatectl show -p Timezone --value 2>/dev/null && return
   fi
   echo "UTC"
}

# Portable short hash (sha1sum on Linux, shasum on macOS).
short_hash() {
   if command -v sha1sum >/dev/null 2>&1; then
      echo -n "$1" | sha1sum | cut -c 1-4
   else
      echo -n "$1" | shasum | cut -c 1-4
   fi
}

container_exists() {
   docker inspect "$1" >/dev/null 2>&1
}

container_running() {
   [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

# ---------------------------------------------------------------------------
# 3. Builders — populate global arrays consumed by `docker run`
# ---------------------------------------------------------------------------

# Populates CONFIG_MOUNTS with --mount args for each existing workspace item.
build_workspace_mounts() {
   CONFIG_MOUNTS=()
   local item src ro_marker mount_spec ro_item
   for item in "${SYNCED_CONFIG_ITEMS[@]}"; do
      src="$WORKSPACE_DIR/$item"
      [ -e "$src" ] || continue
      mount_spec="type=bind,source=$src,target=/opencode/.config/opencode/$item"
      ro_marker=""
      for ro_item in "${SYNCED_CONFIG_ITEMS_READONLY[@]}"; do
         if [ "$item" = "$ro_item" ]; then
            mount_spec="$mount_spec,readonly"
            ro_marker=" (read-only)"
            break
         fi
      done
      CONFIG_MOUNTS+=(--mount "$mount_spec")
      echo "[*] Syncing config item: $item$ro_marker"
   done
}

# Populates NETWORK_ARGS with -p flags. Bridge networking (no --network host)
# on every platform: --network host on Linux would expose host loopback, the
# host LAN, and cloud metadata endpoints to the agent.
build_network_args() {
   NETWORK_ARGS=(-p "127.0.0.1:${OPENCODE_PORT}:${OPENCODE_PORT}")
   echo "[*] Forwarding port 127.0.0.1:${OPENCODE_PORT} -> container:${OPENCODE_PORT} (opencode)"

   [[ -n "${OPENCODE_SANDBOX_PORTS:-}" ]] || return 0

   local p
   IFS=',' read -ra _extra_ports <<< "$OPENCODE_SANDBOX_PORTS"
   for p in "${_extra_ports[@]}"; do
      p="${p// /}"
      [[ -z "$p" ]] && continue
      if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
         echo "[!] Error: invalid port in OPENCODE_SANDBOX_PORTS: '$p'" >&2
         exit 1
      fi
      NETWORK_ARGS+=(-p "127.0.0.1:${p}:${p}")
      echo "[*] Forwarding extra port 127.0.0.1:${p} -> container:${p}"
   done
}

# Populates PROXY_ENV_ARGS with -e flags. The literal "sandbox" key is a
# placeholder; the real key lives in the proxy. ANTHROPIC_BASE_URL /
# OPENAI_BASE_URL are honored by SDKs that don't read opencode.json.
build_proxy_env_args() {
   PROXY_ENV_ARGS=()
   [ "$PROXY_ENABLED" = "1" ] || return 0
   PROXY_ENV_ARGS=(
      -e ANTHROPIC_API_KEY=sandbox
      -e OPENAI_API_KEY=sandbox
      -e ANTHROPIC_BASE_URL="http://${PROXY_CONTAINER}:4000/anthropic"
      -e OPENAI_BASE_URL="http://${PROXY_CONTAINER}:4000/v1"
   )
}

# ---------------------------------------------------------------------------
# 4. Lifecycle
# ---------------------------------------------------------------------------

# Bring the long-lived proxy up (idempotent). No-op if PROXY_ENABLED!=1, the
# compose file is missing, or `docker compose` isn't available.
ensure_proxy_running() {
   [ "$PROXY_ENABLED" = "1" ] || return 0
   if [ ! -f "$PROXY_COMPOSE_FILE" ]; then
      echo "[!] proxy: compose file missing at $PROXY_COMPOSE_FILE — skipping."
      return 0
   fi
   if ! docker compose version >/dev/null 2>&1; then
      echo "[!] proxy: 'docker compose' not available — skipping."
      return 0
   fi
   if container_running "$PROXY_CONTAINER"; then return 0; fi
   echo "[*] Starting LLM proxy ($PROXY_CONTAINER) ..."
   if [ ! -f "$SCRIPT_DIR/.env" ]; then
      echo "[!] proxy: no $SCRIPT_DIR/.env — provider routes will return 503 until you add keys."
   fi
   docker compose -f "$PROXY_COMPOSE_FILE" up -d llm-proxy >/dev/null \
      || echo "[!] proxy: 'docker compose up' failed — continuing without proxy."
}

# Attach the named sandbox container to the proxy network (idempotent).
attach_to_proxy_network() {
   local name="$1"
   [ "$PROXY_ENABLED" = "1" ] || return 0
   docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 || return 0
   if docker inspect "$name" \
         --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null \
         | tr ' ' '\n' | grep -qx "$PROXY_NETWORK"; then
      return 0
   fi
   if docker network connect "$PROXY_NETWORK" "$name" 2>/dev/null; then
      echo "[*] Sandbox attached to proxy network — proxy reachable at http://$PROXY_CONTAINER:4000"
   fi
}

# Create the sandbox container and wait for it to reach a running state.
# Args: <container-name> <workdir>
create_sandbox_container() {
   local name="$1" workdir="$2"

   build_workspace_mounts
   build_network_args
   build_proxy_env_args

   docker run --cap-add=NET_RAW --cap-add=NET_ADMIN --name "$name" -d \
      ${CONFIG_MOUNTS[@]+"${CONFIG_MOUNTS[@]}"} \
      --mount "type=bind,source=$workdir,target=$workdir" \
      --workdir "$workdir" \
      -e TZ="$(detect_tz)" \
      -e OPENCODE_PORT="$OPENCODE_PORT" \
      ${PROXY_ENV_ARGS[@]+"${PROXY_ENV_ARGS[@]}"} \
      "${NETWORK_ARGS[@]}" \
      "$OPENCODE_SANDBOX_IMAGE_DOCKER" bash -c "while true; do sleep 3600; done" \
      || { echo "[!] Error: The container could not be started."; exit 1; }

   local state=""
   local i
   for i in $(seq 1 30); do
      state=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)
      [ "$state" = "true" ] && break
      sleep 1
   done
   if [ "$state" != "true" ]; then
      echo "[!] Error: timed out waiting for container '$name' to reach running state."
      exit 1
   fi
}

# Run workspace/install.sh inside the container, if present.
run_install_hook() {
   [ -f "$WORKSPACE_DIR/install.sh" ] || return 0
   echo "[*] Running install.sh ..."
   docker exec -it "$1" bash /opencode/.config/opencode/install.sh
}

# ---------------------------------------------------------------------------
# 5. Subcommand dispatch
# ---------------------------------------------------------------------------

# 5a. Project-independent subcommands — handle and exit before resolving any
# project context (so they work from any CWD).
case "${1:-}" in
   help|-h|--help)
      print_help
      exit 0
      ;;
   proxy)
      sub="${2:-status}"
      case "$sub" in
         up)     docker compose -f "$PROXY_COMPOSE_FILE" up -d llm-proxy ;;
         down)   docker compose -f "$PROXY_COMPOSE_FILE" down ;;
         logs)   docker compose -f "$PROXY_COMPOSE_FILE" logs -f llm-proxy ;;
         status) docker ps --filter "name=^${PROXY_CONTAINER}$" \
                    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
         *) echo "Usage: ocsandbox proxy [up|down|logs|status]" >&2; exit 1 ;;
      esac
      exit 0
      ;;
esac

# 5b. Resolve project context: CWD must live under the allowed dir, and the
# container name is derived from that allowed dir (so the same project always
# resolves to the same container).
CURRENT_DIR=$(pwd)

# Bash 3.2-compatible "is variable set" check (replaces `[[ -v VAR ]]`).
if [[ -z "${OPENCODE_SANDBOX_ALLOWED_DIR+x}" ]]; then
   OPENCODE_SANDBOX_ALLOWED_DIR=$CURRENT_DIR
fi
OPENCODE_SANDBOX_ALLOWED_DIR="${OPENCODE_SANDBOX_ALLOWED_DIR/#\~/$HOME}"

case "$CURRENT_DIR/" in
   "$OPENCODE_SANDBOX_ALLOWED_DIR"/*) ;;
   *) echo "[!] Error: this command must be used just only in '$OPENCODE_SANDBOX_ALLOWED_DIR'" >&2
      exit 1 ;;
esac

raw=$(basename "$OPENCODE_SANDBOX_ALLOWED_DIR")
FOLDER_NAME=${raw//[^a-zA-Z0-9_.-]/-}
HASH_DIR=$(short_hash "$OPENCODE_SANDBOX_ALLOWED_DIR")
OPENCODE_SANDBOX_CONTAINER_NAME=${OPENCODE_SANDBOX_CONTAINER_NAME:-ocsandbox-$FOLDER_NAME-$HASH_DIR}

# 5c. Project-scoped subcommand: destroy (uses container name from above).
if [[ "${1:-}" = "destroy" ]]; then
   echo "[*] Deleting container '$OPENCODE_SANDBOX_CONTAINER_NAME'..."
   docker stop "$OPENCODE_SANDBOX_CONTAINER_NAME" >/dev/null 2>&1 || true
   docker rm   "$OPENCODE_SANDBOX_CONTAINER_NAME" >/dev/null 2>&1 \
      && echo "[+] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' deleted."
   exit 0
fi

# 5d. Ensure the sandbox container is up: create if missing, start if stopped.
if ! container_exists "$OPENCODE_SANDBOX_CONTAINER_NAME"; then
   echo "[*] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' does not exist."
   echo "[*] Creating with workspace: $WORKSPACE_DIR"

   ensure_proxy_running

   # Random high port (avoids collisions when several sandboxes coexist).
   if [[ -z "${OPENCODE_PORT:-}" ]]; then
      OPENCODE_PORT=$(( (RANDOM % 16384) + 49152 ))
   fi

   create_sandbox_container "$OPENCODE_SANDBOX_CONTAINER_NAME" "$OPENCODE_SANDBOX_ALLOWED_DIR"
   attach_to_proxy_network "$OPENCODE_SANDBOX_CONTAINER_NAME"
   run_install_hook        "$OPENCODE_SANDBOX_CONTAINER_NAME"
elif container_running "$OPENCODE_SANDBOX_CONTAINER_NAME"; then
   echo "[+] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' is already running."
else
   echo "[*] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' is stopped. Starting it now..."
   ensure_proxy_running
   docker start "$OPENCODE_SANDBOX_CONTAINER_NAME" >/dev/null || exit 1
fi

# Re-attach on every invocation. `proxy down && proxy up` recreates the proxy
# network, and previously-attached sandboxes need to reconnect to keep reaching it.
attach_to_proxy_network "$OPENCODE_SANDBOX_CONTAINER_NAME"

# 5e. Subcommand needing the container running: update.
if [ "${1:-}" = "update" ]; then
   echo "[*] Updating opencode ..."
   docker exec -it -u root "$OPENCODE_SANDBOX_CONTAINER_NAME" sh -c \
      "curl -fsSL https://opencode.ai/install | bash && mv /root/.opencode/bin/opencode /usr/local/bin/"
   echo "[+] Done."
   exit 0
fi

# 5f. Default action: exec opencode (or `bash`) inside the running container.
if [ "${1:-}" = "bash" ]; then
   CMD=("bash" "${@:2}")
else
   CMD=("opencode" "$@")
fi

echo "[*] Running ${CMD[*]}"
echo "    workdir:    $CURRENT_DIR"
echo "    workspace:  $WORKSPACE_DIR"
echo
sleep 1

# Stop the container on exit so the sandbox doesn't keep running after the
# interactive session ends. The container is left in place and reused next time.
cleanup_container() {
   echo
   echo "[*] Stopping container '$OPENCODE_SANDBOX_CONTAINER_NAME'..."
   docker stop "$OPENCODE_SANDBOX_CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT INT TERM

docker exec -it -w "$CURRENT_DIR" "$OPENCODE_SANDBOX_CONTAINER_NAME" "${CMD[@]}"
