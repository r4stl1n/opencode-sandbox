#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" = "help" ]]; then

   # Help message
   echo "opencode sandbox for docker."
   echo "Usage: ./opencode-sandbox.sh [command] [args]"
   echo
   echo "Commands:"
   echo "  help     Show this help message."
   echo "  bash     Start a bash session inside the container."
   echo "  destroy  Stop and remove the sandbox container."
   echo "  update   Update opencode version."
   echo "  (none)   Run the 'opencode' command inside the container (default)."
   echo

   exit
fi

CURRENT_DIR=$(pwd)

# Bash 3.2-compatible "is variable set" check (replaces `[[ -v VAR ]]`).
# Works on macOS's default /bin/bash as well as modern bash/zsh-invoked-as-bash.
if [[ -z "${OPENCODE_SANDBOX_ALLOWED_DIR+x}" ]]; then
   OPENCODE_SANDBOX_ALLOWED_DIR=$CURRENT_DIR
fi

# Expand a leading ~ in OPENCODE_SANDBOX_ALLOWED_DIR (since it may come from an
# env var where tilde isn't expanded by the shell).
OPENCODE_SANDBOX_ALLOWED_DIR="${OPENCODE_SANDBOX_ALLOWED_DIR/#\~/$HOME}"

case "$CURRENT_DIR/" in
    "$OPENCODE_SANDBOX_ALLOWED_DIR"/*) ;;
    *)
        echo "[!] Error: this command must be used just only in '$OPENCODE_SANDBOX_ALLOWED_DIR'"
        exit 1
        ;;
esac

# docker image (default: opencode-sandbox)
OPENCODE_SANDBOX_IMAGE_DOCKER=${OPENCODE_SANDBOX_IMAGE_DOCKER:-opencode-sandbox}

# Host directory containing the opencode config items we want synced into the
# container's /opencode/.config/opencode. Only specific entries are mounted
# (see SYNCED_CONFIG_ITEMS below) so that opencode's runtime plugin install
# (node_modules, package.json, lockfiles) stays container-internal instead of
# leaking back onto the host.
OPENCODE_SANDBOX_HOME=${OPENCODE_SANDBOX_HOME:-~/.opencode_sandbox_home}
# Expand ~ if present
OPENCODE_SANDBOX_HOME="${OPENCODE_SANDBOX_HOME/#\~/$HOME}"

# create sandbox config dir if not exists
if [ ! -d "$OPENCODE_SANDBOX_HOME" ]; then
   echo "[*] Creating sandbox config dir: $OPENCODE_SANDBOX_HOME ..."
   mkdir -p "$OPENCODE_SANDBOX_HOME"
fi

# Items under $OPENCODE_SANDBOX_HOME that get bind-mounted into the container's
# config dir. Each one is mounted only if it exists on the host.
SYNCED_CONFIG_ITEMS=("opencode.json" "AGENTS.md" "skills" "tools" "install.sh")
# Subset of the above that must be mounted read-only. These are user-managed
# config that the sandboxed agent should never write back to the host (the
# install.sh entry in particular is auto-executed on container creation, so
# letting the agent edit it would be a host-persistence vector).
SYNCED_CONFIG_ITEMS_READONLY=("opencode.json" "AGENTS.md" "install.sh")

# Detect local timezone in a portable way (timedatectl is Linux-only).
detect_tz() {
   # 1) Honor an explicit TZ env var if already set
   if [[ -n "${TZ:-}" ]]; then
      echo "$TZ"
      return
   fi
   # 2) macOS / many Linux distros: /etc/localtime is a symlink into zoneinfo
   if [[ -L /etc/localtime ]]; then
      local link
      link=$(readlink /etc/localtime 2>/dev/null)
      # Strip everything up to and including "/zoneinfo/"
      case "$link" in
         */zoneinfo/*) echo "${link##*/zoneinfo/}"; return ;;
      esac
   fi
   # 3) Some Linux distros: /etc/timezone is a plain text file
   if [[ -r /etc/timezone ]]; then
      cat /etc/timezone
      return
   fi
   # 4) Linux with timedatectl available
   if command -v timedatectl >/dev/null 2>&1; then
      timedatectl show -p Timezone --value 2>/dev/null && return
   fi
   # 5) Fallback
   echo "UTC"
}
TZ=$(detect_tz)

# Portable short hash of the allowed dir (sha1sum is Linux; shasum is on macOS).
# Used as a stable 4-char suffix so the same folder always resolves to the same
# container (random-per-invocation would break container reuse).
if command -v sha1sum >/dev/null 2>&1; then
   HASH_DIR=$(echo -n "$OPENCODE_SANDBOX_ALLOWED_DIR" | sha1sum | cut -c 1-4)
else
   HASH_DIR=$(echo -n "$OPENCODE_SANDBOX_ALLOWED_DIR" | shasum | cut -c 1-4)
fi

# Folder basename, sanitized to docker-safe chars ([a-zA-Z0-9_.-]).
raw=$(basename "$OPENCODE_SANDBOX_ALLOWED_DIR")
FOLDER_NAME=${raw//[^a-zA-Z0-9_.-]/-}

# container name (default: ocsandbox-<folder>-<hash>)
OPENCODE_SANDBOX_CONTAINER_NAME=${OPENCODE_SANDBOX_CONTAINER_NAME:-ocsandbox-$FOLDER_NAME-$HASH_DIR}

if [[ "${1:-}" = "destroy" ]]; then
   echo "[*] Deleting container '$OPENCODE_SANDBOX_CONTAINER_NAME'..."
   docker stop "$OPENCODE_SANDBOX_CONTAINER_NAME" > /dev/null && \
      docker rm "$OPENCODE_SANDBOX_CONTAINER_NAME" > /dev/null && \
      echo "[+] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' deleted."

   exit
fi

# Check if the container exists and get its running state
if ! RUNNING=$(docker inspect -f '{{.State.Running}}' "$OPENCODE_SANDBOX_CONTAINER_NAME" 2>/dev/null); then
   RUNNING=""
fi

if [ -z "$RUNNING" ]; then # if the container doesn't exist
   echo "[*] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' does not exist."
   echo "[*] Creating with home from: $OPENCODE_SANDBOX_HOME"

   # Pick a random high port if not explicitly set, so multiple sandboxes
   # can coexist without colliding on a fixed port.
   if [[ -z "${OPENCODE_PORT:-}" ]]; then
      OPENCODE_PORT=$(( (RANDOM % 16384) + 49152 ))
   fi

   # Use bridge networking with explicit loopback port publishing on every
   # platform. --network host on Linux would put the container in the host's
   # network namespace, giving the sandboxed agent direct access to host
   # loopback services, the host LAN, and cloud metadata endpoints — which
   # defeats the point of the sandbox.
   NETWORK_ARGS=(-p "127.0.0.1:${OPENCODE_PORT}:${OPENCODE_PORT}")
   echo "[*] Forwarding port 127.0.0.1:${OPENCODE_PORT} -> container:${OPENCODE_PORT} (opencode)"

   # Extra ports for things like dev servers (e.g. OPENCODE_SANDBOX_PORTS="3000,5173").
   if [[ -n "${OPENCODE_SANDBOX_PORTS:-}" ]]; then
      IFS=',' read -ra EXTRA_PORTS <<< "$OPENCODE_SANDBOX_PORTS"
      for p in "${EXTRA_PORTS[@]}"; do
         p="${p// /}"
         [[ -z "$p" ]] && continue
         if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            echo "[!] Error: invalid port in OPENCODE_SANDBOX_PORTS: '$p'"
            exit 1
         fi
         NETWORK_ARGS+=(-p "127.0.0.1:${p}:${p}")
         echo "[*] Forwarding extra port 127.0.0.1:${p} -> container:${p}"
      done
   fi

   CONFIG_MOUNTS=()
   for item in "${SYNCED_CONFIG_ITEMS[@]}"; do
      src="$OPENCODE_SANDBOX_HOME/$item"
      if [ -e "$src" ]; then
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
      fi
   done

   docker run --name "$OPENCODE_SANDBOX_CONTAINER_NAME" -d \
      ${CONFIG_MOUNTS[@]+"${CONFIG_MOUNTS[@]}"} \
      --mount "type=bind,source=$OPENCODE_SANDBOX_ALLOWED_DIR,target=$OPENCODE_SANDBOX_ALLOWED_DIR" \
      --workdir "$OPENCODE_SANDBOX_ALLOWED_DIR" \
      -e TZ="$TZ" \
      -e OPENCODE_PORT="$OPENCODE_PORT" \
      "${NETWORK_ARGS[@]}" \
      "$OPENCODE_SANDBOX_IMAGE_DOCKER" bash -c "while true; do sleep 3600; done" \
      || { echo "[!] Error: The container could not be started."; exit 1; }

   # Poll for running state up to 30s instead of a blind sleep.
   for _ in $(seq 1 30); do
      STATE=$(docker inspect -f '{{.State.Running}}' "$OPENCODE_SANDBOX_CONTAINER_NAME" 2>/dev/null || true)
      if [ "$STATE" = "true" ]; then
         break
      fi
      sleep 1
   done
   if [ "${STATE:-}" != "true" ]; then
      echo "[!] Error: timed out waiting for container '$OPENCODE_SANDBOX_CONTAINER_NAME' to reach running state."
      exit 1
   fi

   if [ -f "$OPENCODE_SANDBOX_HOME/install.sh" ]; then
      echo "[*] Running install.sh ..."
      docker exec -it "$OPENCODE_SANDBOX_CONTAINER_NAME" bash /opencode/.config/opencode/install.sh
   fi

   RUNNING=true
fi

if [ "$RUNNING" == "true" ]; then
   echo "[+] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' is already running."
else
   echo "[*] Container '$OPENCODE_SANDBOX_CONTAINER_NAME' is stopped. Starting it now..."
   docker start "$OPENCODE_SANDBOX_CONTAINER_NAME" > /dev/null || exit 1
fi


if [ "${1:-}" = "update" ]; then
   echo "[*] Updating opencode ..."
   docker exec -it -u root \
      "$OPENCODE_SANDBOX_CONTAINER_NAME" sh -c \
      "curl -fsSL https://opencode.ai/install | bash  && mv /root/.opencode/bin/opencode /usr/local/bin/"
   echo "[+] Done."
   exit 0
fi

CMD1="opencode"
# Use an array so arguments with spaces survive intact.
PARAMS=("$@")


if [ "${1:-}" = "bash" ]; then
   CMD1="bash"
   PARAMS=("${@:2}")
fi


echo "[*] Running $CMD1 ${PARAMS[*]:-}"
echo "    workdir:   $CURRENT_DIR"
echo "    home from: $OPENCODE_SANDBOX_HOME"
echo
sleep 1

# Stop the container on exit (Ctrl+C, normal quit, or error) so the sandbox
# doesn't keep running after the interactive session ends. The container is
# left in place and will be reused on the next invocation.
cleanup_container() {
   echo
   echo "[*] Stopping container '$OPENCODE_SANDBOX_CONTAINER_NAME'..."
   docker stop "$OPENCODE_SANDBOX_CONTAINER_NAME" > /dev/null 2>&1 || true
}
trap cleanup_container EXIT INT TERM

docker exec -it \
   -w "$CURRENT_DIR" \
   "$OPENCODE_SANDBOX_CONTAINER_NAME" "$CMD1" ${PARAMS[@]:+"${PARAMS[@]}"}
