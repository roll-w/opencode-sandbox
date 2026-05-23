#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [options] [project_path] [-- [opencode_args...]]

Options:
  -i, --image IMAGE         Docker image to use (overrides auto-detection)
  -c, --config DIR          Config directory (default: ~/.config/opencode)
  -n, --name NAME           Container name (default: opencode-<timestamp>)
  -w, --workdir DIR         Container working dir (default: /workspace)
  -u, --user UID[:GID]      Run as specified user (forwarded to docker --user)
  -U, --update              Pull image to check for updates before running
  -P, --http-proxy URL      HTTP proxy to pass into container
      --https-proxy URL     HTTPS proxy to pass into container
      --no-proxy LIST       Comma-separated no_proxy list
  -p, --port PORT           Port mapping to expose (repeatable). Accepts:
                            - host_ip:host_port:container_port (e.g. 127.0.0.1:8080:8080)
                            - host_port:container_port (e.g. 8080:8080)
                            - container_port (e.g. 8080) which maps the same port on the host
                            Can be repeated to add multiple mappings.
  -N, --network MODE        Docker network mode or network name to pass to --network
  -m, --mount HOST:CONTAINER[:ro|rw]
                            Additional mount (repeatable). HOST may be relative; CONTAINER
                            may be absolute or relative to the container workdir.
      --toolchain-volume-name NAME
                            Base Docker volume name prefix for grouped toolchain cache volumes.
      --toolchain-preset NAME
                            Enable a toolchain preset or comma-separated preset list.
                            Repeatable. No default presets are enabled.
      --toolchain-path CONTAINER_PATH
                            Add an extra container path that mounts from the shared CLI toolchain volume.
      --dry-run             Print the final docker command and exit without running it
  -E, --env KEY=VAL         Pass an environment variable into the container (may repeat)
      --env-file FILE       Pass an env file to docker (each line VAR=VAL)
      --no-auto-forward     Do not automatically forward host OPENCODE_* env vars
  -M, --mode MODE           Startup mode: opencode (default), web, shell
  -k, --keep-running        Keep the container running after the session exits
  -h, --help                Show this help

--mode choices:
  opencode  Directly run opencode [args...] (default)
  web       Run opencode web [args...] inside container
  shell     Start the container and open a shell (no opencode process)

Arguments after -- are forwarded as CLI options to opencode or opencode web (not used for shell mode).

  Examples:
  $0
  $0 -i ghcr.io/roll-w/opencode-sandbox:main /path/to/project
  $0 --mode web -- --port 8123
  $0 --mode shell
  $0 -P http://proxy:3128 -E OPENCODE_DISABLE_LSP_DOWNLOAD=false
  $0 -p 8080:8080 -N host /path/to/project
  $0 --toolchain-preset java,go /path/to/project
  $0 --toolchain-preset dotnet --toolchain-path /home/opencode/.cache/uv /path/to/project

Toolchain cache targets selected through the same preset share one Docker volume.
Each target mounts its own subdirectory from that shared volume.
Presets are loaded from config/toolchain-volume-presets.conf in this repo and from
the configured config dir's toolchain-volume-presets.conf when present.
Each non-empty preset line should use: preset_name:container_path
EOF
}

# Defaults
IMAGE=""
PROJECT_PATH=""
CONFIG_DIR=""
CONTAINER_WORKDIR="/workspace"
NAME="opencode-temp"
NAME_SET=false
KEEP_CONTAINER_RUNNING=false

# Proxy defaults (empty by default; only set when provided)
HTTP_PROXY_DEFAULT=""
HTTPS_PROXY_DEFAULT=""
NO_PROXY_DEFAULT=""

# Port mappings collected from -p/--port
PORT_MAPPINGS=()

# Network mode (passed to docker --network)
NETWORK_MODE=""

# Collected docker env args
ENV_ARGS=()
ENV_FILE=""
AUTO_FORWARD_OPENCODE=true
# Additional mounts provided by user with -m/--mount; can repeat.
# Syntax: host_path:container_path[:ro|rw]
# - host_path: absolute or relative host path (will be canonicalized)
# - container_path: absolute path inside container or relative (resolved under CONTAINER_WORKDIR)
# - mode: optional, either 'ro' or 'rw' (default: rw)
MOUNTS=()
TOOLCHAIN_VOLUME_TARGETS=()
TOOLCHAIN_VOLUME_MOUNTS=()
TOOLCHAIN_SHARED_VOLUMES=()
FOUND_TOOLCHAIN_PRESETS=()
DRY_RUN=false
PULL_UPDATE=false

# Startup mode: opencode (default), web, or shell
MODE="opencode"
OPENCODE_ARGS=()

USER_SPEC=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_VOLUME_NAME="opencode-sandbox-toolchains"
TOOLCHAIN_PREPARE_MOUNT_PATH="/toolchain-volume"
TOOLCHAIN_PRESET_ARGS=()
TOOLCHAIN_PRESETS=()
TOOLCHAIN_PATH_ARGS=()

add_toolchain_preset() {
  local preset="$1"
  local existing

  if [ -z "$preset" ]; then
    return
  fi

  for existing in "${TOOLCHAIN_PRESETS[@]}"; do
    if [ "$existing" = "$preset" ]; then
      return
    fi
  done

  TOOLCHAIN_PRESETS+=("$preset")
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)
      IMAGE="$2"; shift 2 ;;
    -c|--config)
      CONFIG_DIR="$2"; shift 2 ;;
    -n|--name)
      NAME="$2"; NAME_SET=true; shift 2 ;;
    -w|--workdir)
      CONTAINER_WORKDIR="$2"; shift 2 ;;
    -u|--user)
      USER_SPEC="$2"; shift 2 ;;
    -U|--update)
      PULL_UPDATE=true; shift ;;
    -m|--mount)
      # Accept mounts like host:container or host:container:ro
      MOUNTS+=("$2"); shift 2 ;;
    --toolchain-volume-name)
      TOOLCHAIN_VOLUME_NAME="$2"; shift 2 ;;
    --toolchain-preset)
      TOOLCHAIN_PRESET_ARGS+=("$2"); shift 2 ;;
    --toolchain-path)
      TOOLCHAIN_PATH_ARGS+=("$2"); shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -P|--http-proxy)
      HTTP_PROXY="$2"; shift 2 ;;
    --https-proxy)
      HTTPS_PROXY="$2"; shift 2 ;;
    --no-proxy)
      NO_PROXY="$2"; shift 2 ;;
    -p|--port)
      PORT_MAPPINGS+=("$2"); shift 2 ;;
    -N|--network)
      NETWORK_MODE="$2"; shift 2 ;;
    -E|--env)
      ENV_ARGS+=("-e" "$2"); shift 2 ;;
    --env-file)
      ENV_FILE="$2"; shift 2 ;;
    --no-auto-forward)
      AUTO_FORWARD_OPENCODE=false; shift ;;
    -M|--mode)
      MODE="$2"; shift 2 ;;
    -k|--keep-running)
      KEEP_CONTAINER_RUNNING=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift
      # After --, all args go to opencode/web
      OPENCODE_ARGS=("$@")
      break ;;
    -* )
      echo "Unknown option: $1" >&2; usage; exit 1 ;;
    * )
      if [ -z "$PROJECT_PATH" ]; then PROJECT_PATH="$1"; shift; else echo "Unexpected argument: $1" >&2; usage; exit 1; fi ;;
  esac
done

# Set remaining defaults
if [ -z "$IMAGE" ]; then
  IMAGE="ghcr.io/roll-w/opencode-sandbox:main"
fi

PROJECT_PATH="${PROJECT_PATH:-$(pwd)}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/opencode}"
TOOLCHAIN_PRESETS_FILE="$CONFIG_DIR/toolchain-volume-presets.conf"
BUILTIN_TOOLCHAIN_PRESETS_FILE="$SCRIPT_DIR/config/toolchain-volume-presets.conf"

if [ "$NAME_SET" != true ]; then
  NAME="opencode-$(date +%s)"
fi

if [ "$DRY_RUN" != true ]; then
  if [ "$PULL_UPDATE" = true ]; then
    echo "Checking for image updates..."
    docker pull "$IMAGE"
  elif ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image '$IMAGE' not found locally. Pulling..."
    docker pull "$IMAGE"
  fi
fi

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: Project path '$PROJECT_PATH' does not exist or is not a directory." >&2
  exit 1
fi
mkdir -p "$CONFIG_DIR"

if [ -z "$TOOLCHAIN_VOLUME_NAME" ]; then
  echo "Error: toolchain volume name must not be empty." >&2
  exit 1
fi

if [ -n "$USER_SPEC" ]; then
  SPEC_UID="${USER_SPEC%%:*}"
  if [ "$SPEC_UID" = "0" ]; then
    HOME_IN_CONTAINER="/root"
  else
    HOME_IN_CONTAINER="/home/opencode"
  fi
else
  HOME_IN_CONTAINER="/home/opencode"
fi

PNPM_STORE_HOST="${HOME}/.local/share/pnpm/store"
if command -v pnpm >/dev/null 2>&1; then
  PNPM_DETECTED=$(pnpm store path 2>/dev/null || true)
  if [ -n "$PNPM_DETECTED" ]; then
    PNPM_STORE_HOST=$(dirname "$PNPM_DETECTED")
  fi
fi

# Determine proxy values, prefer explicit flags/env then fall back to defaults
HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-${HTTP_PROXY_DEFAULT}}}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-${HTTPS_PROXY_DEFAULT}}}"
NO_PROXY="${NO_PROXY:-${no_proxy:-${NO_PROXY_DEFAULT}}}"

# Convert localhost / 127.0.0.1 in proxy hosts to host.docker.internal (so container can reach host)
convert_localhost_to_docker() {
  local url="$1"
  if [ -z "$url" ]; then
    echo "$url"
    return
  fi
  # Replace occurrences of localhost or 127.0.0.1 with host.docker.internal
  # Handles forms: http://localhost:3128, localhost:3128, http://127.0.0.1:8080
  printf '%s' "$url" | sed -E 's#(://)?(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+)#\1host.docker.internal#g'
}

# Apply conversion
HTTP_PROXY="$(convert_localhost_to_docker "$HTTP_PROXY")"
HTTPS_PROXY="$(convert_localhost_to_docker "$HTTPS_PROXY")"
# For NO_PROXY we need to replace occurrences inside a comma-separated list
if [ -n "$NO_PROXY" ]; then
  # replace standalone entries
  NO_PROXY="$(printf '%s' "$NO_PROXY" | sed -E 's/(^|,)\s*(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+)\s*(,|$)/\1host.docker.internal\3/g')"
fi

# Add proxy envs to forwarded args
if [ -n "$HTTP_PROXY" ]; then ENV_ARGS+=("-e" "http_proxy=$HTTP_PROXY" "-e" "HTTP_PROXY=$HTTP_PROXY"); fi
if [ -n "$HTTPS_PROXY" ]; then ENV_ARGS+=("-e" "https_proxy=$HTTPS_PROXY" "-e" "HTTPS_PROXY=$HTTPS_PROXY"); fi
if [ -n "$NO_PROXY" ]; then ENV_ARGS+=("-e" "no_proxy=$NO_PROXY" "-e" "NO_PROXY=$NO_PROXY"); fi

# Forward OPENCODE_* env vars from host by default
if [ "$AUTO_FORWARD_OPENCODE" = true ]; then
  # iterate over current environment and forward OPENCODE_* variables
  while IFS='=' read -r k v; do
    if [[ $k == OPENCODE_* ]]; then
      ENV_ARGS+=("-e" "$k=$v")
    fi
  done < <(env)
fi

# Compute container mount path: preserve host path under container workdir
# Make PROJECT_PATH absolute (canonicalize) to build a predictable container path
PROJECT_HOST_PATH="$(cd "$PROJECT_PATH" && pwd)"
# Remove any trailing slash from CONTAINER_WORKDIR to avoid double slashes
CONTAINER_WORKDIR="${CONTAINER_WORKDIR%/}"
CONTAINER_PROJECT_PATH="$CONTAINER_WORKDIR$PROJECT_HOST_PATH"
DEFAULT_BIND_TARGETS=(
  "${HOME_IN_CONTAINER}/.bun"
  "${HOME_IN_CONTAINER}/.pnpm-store"
  "${HOME_IN_CONTAINER}/.cache/opencode"
  "${HOME_IN_CONTAINER}/.local/state/opencode"
  "${HOME_IN_CONTAINER}/.local/share/opencode"
  "${HOME_IN_CONTAINER}/.config/opencode"
  "${HOME_IN_CONTAINER}/.agents"
  "${HOME_IN_CONTAINER}/.config/openspec"
  "$CONTAINER_PROJECT_PATH"
)

resolve_container_path() {
  local container_path="$1"

  if [[ "$container_path" = /* ]]; then
    printf '%s' "$container_path"
    return
  fi

  printf '%s/%s' "$CONTAINER_WORKDIR" "$container_path"
}

normalize_container_path() {
  local container_path normalized part
  local -a path_parts

  container_path="$(resolve_container_path "$1")"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$container_path"
    return
  fi

  normalized="/"
  IFS='/' read -r -a path_parts <<<"${container_path#/}"

  for part in "${path_parts[@]}"; do
    case "$part" in
      ''|.)
        continue
        ;;
      ..)
        if [ "$normalized" != "/" ]; then
          normalized="${normalized%/*}"
          if [ -z "$normalized" ]; then
            normalized="/"
          fi
        fi
        ;;
      *)
        if [ "$normalized" = "/" ]; then
          normalized="/$part"
        else
          normalized="$normalized/$part"
        fi
        ;;
    esac
  done

  printf '%s' "$normalized"
}

trim_whitespace() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

expand_toolchain_preset_args() {
  local raw_preset part
  local -a preset_parts

  for raw_preset in "${TOOLCHAIN_PRESET_ARGS[@]}"; do
    IFS=',' read -r -a preset_parts <<<"$raw_preset"
    for part in "${preset_parts[@]}"; do
      add_toolchain_preset "$(trim_whitespace "$part")"
    done
  done
}

# Process user-provided mounts
# Each mount is host_path:container_path[:mode]
process_mount() {
  local raw="$1"
  # Split into host, container, and optional mode
  IFS=':' read -r host_path container_path mode <<<"$raw"
  # container_path is required
  if [ -z "$container_path" ]; then
    echo "Invalid mount specification: $raw" >&2; return 1
  fi
  # Make host_path absolute if relative
  if [[ "$host_path" != /* ]]; then host_path="$(cd "$host_path" && pwd)"; fi
  if [ ! -e "$host_path" ]; then echo "Warning: host path '$host_path' does not exist" >&2; fi
  # Default mode to rw when not provided
  if [ -z "$mode" ]; then mode="rw"; fi
  if [ "$mode" != "ro" ] && [ "$mode" != "rw" ]; then
    echo "Invalid mount mode '$mode' in '$raw' (must be ro or rw)" >&2; return 1
  fi
  container_path="$(normalize_container_path "$container_path")"
  # Output the mount spec only (host:container:mode). Caller will add the -v flag separately.
  printf '%s' "$host_path:$container_path:$mode"
}

has_toolchain_target() {
  local target="$1"
  local existing

  for existing in "${TOOLCHAIN_VOLUME_TARGETS[@]}"; do
    if [ "$existing" = "$target" ]; then
      return 0
    fi
  done

  return 1
}

has_explicit_target() {
  local target="$1"
  local raw source container_path mode

  target="$(normalize_container_path "$target")"

  for raw in "${MOUNTS[@]}"; do
    IFS=':' read -r source container_path mode <<<"$raw"
    if [ -n "$container_path" ] && [ "$(normalize_container_path "$container_path")" = "$target" ]; then
      return 0
    fi
  done

  return 1
}

paths_overlap() {
  local left
  local right

  left="$(normalize_container_path "$1")"
  right="$(normalize_container_path "$2")"

  if [ "$left" = "$right" ]; then
    return 0
  fi

  if [ "$left" = "/" ] || [ "$right" = "/" ]; then
    return 0
  fi

  case "$left" in
    "$right"/*)
      return 0
      ;;
  esac

  case "$right" in
    "$left"/*)
      return 0
      ;;
  esac

  return 1
}

find_bind_target_conflict() {
  local target="$1"
  local bind_target raw source container_path mode

  target="$(normalize_container_path "$target")"

  for bind_target in "${DEFAULT_BIND_TARGETS[@]}"; do
    if paths_overlap "$target" "$bind_target"; then
      printf '%s' "$bind_target"
      return 0
    fi
  done

  for raw in "${MOUNTS[@]}"; do
    IFS=':' read -r source container_path mode <<<"$raw"
    if [ -n "$container_path" ]; then
      bind_target="$(normalize_container_path "$container_path")"
      if paths_overlap "$target" "$bind_target"; then
        printf '%s' "$bind_target"
        return 0
      fi
    fi
  done

  return 1
}

is_selected_toolchain_preset() {
  local preset="$1"
  local selected

  for selected in "${TOOLCHAIN_PRESETS[@]}"; do
    if [ "$selected" = "$preset" ]; then
      return 0
    fi
  done

  return 1
}

toolchain_volume_name_for_group() {
  local source_name="$1"
  local normalized_source digest

  normalized_source="$(printf '%s' "$source_name" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_.-' '-')"
  normalized_source="${normalized_source#-}"
  normalized_source="${normalized_source%-}"

  if [ -z "$normalized_source" ]; then
    normalized_source="toolchain"
  fi

  set -- $(printf '%s' "$source_name" | cksum)
  digest="$1"
  printf '%s-%s-%s' "$TOOLCHAIN_VOLUME_NAME" "$normalized_source" "$digest"
}

toolchain_subpath_for_target() {
  local target_path="$1"

  set -- $(printf '%s' "$target_path" | cksum)
  printf 'target-%s' "$1"
}

has_toolchain_shared_volume() {
  local volume_name="$1"
  local existing

  for existing in "${TOOLCHAIN_SHARED_VOLUMES[@]}"; do
    if [ "$existing" = "$volume_name" ]; then
      return 0
    fi
  done

  return 1
}

find_toolchain_target_conflict() {
  local target="$1"
  local existing

  target="$(normalize_container_path "$target")"

  for existing in "${TOOLCHAIN_VOLUME_TARGETS[@]}"; do
    if [ "$target" = "$existing" ]; then
      continue
    fi

    if paths_overlap "$target" "$existing"; then
      printf '%s' "$existing"
      return 0
    fi
  done

  return 1
}

mark_toolchain_preset_found() {
  local preset="$1"
  local existing

  for existing in "${FOUND_TOOLCHAIN_PRESETS[@]}"; do
    if [ "$existing" = "$preset" ]; then
      return
    fi
  done

  FOUND_TOOLCHAIN_PRESETS+=("$preset")
}

register_toolchain_target() {
  local source_name="$1"
  local target_path="$2"
  local conflicting_bind_target
  local conflicting_toolchain_target
  local volume_name
  local subpath

  if [ -z "$source_name" ]; then
    echo "Invalid toolchain source name: '$source_name'" >&2; return 1
  fi

  if [ -z "$target_path" ]; then
    echo "Invalid toolchain target: '$target_path'" >&2; return 1
  fi

  target_path="$(normalize_container_path "$target_path")"

  if [ "$target_path" = "/" ]; then
    echo "Error: toolchain target '/' is not allowed." >&2
    return 1
  fi

  volume_name="$(toolchain_volume_name_for_group "$source_name")"
  subpath="$(toolchain_subpath_for_target "$target_path")"

  if conflicting_bind_target="$(find_bind_target_conflict "$target_path")"; then
    echo "Error: toolchain target '$target_path' overlaps bind mount target '$conflicting_bind_target'." >&2
    return 1
  fi

  if conflicting_toolchain_target="$(find_toolchain_target_conflict "$target_path")"; then
    echo "Error: toolchain target '$target_path' overlaps toolchain target '$conflicting_toolchain_target'." >&2
    return 1
  fi

  if has_explicit_target "$target_path" || has_toolchain_target "$target_path"; then
    return
  fi

  TOOLCHAIN_VOLUME_TARGETS+=("$target_path")
  if ! has_toolchain_shared_volume "$volume_name"; then
    TOOLCHAIN_SHARED_VOLUMES+=("$volume_name")
  fi
  TOOLCHAIN_VOLUME_MOUNTS+=("${volume_name}|${subpath}|${target_path}|${source_name}")
}

load_toolchain_preset_file() {
  local preset_file="$1"
  local raw line preset_name target_path ignored_extra

  if [ ! -f "$preset_file" ]; then
    return
  fi

  while IFS= read -r raw || [ -n "$raw" ]; do
    line="$(trim_whitespace "$raw")"
    case "$line" in
      ''|'#'*)
        continue
        ;;
    esac

    IFS=':' read -r preset_name target_path ignored_extra <<<"$line"
    preset_name="$(trim_whitespace "$preset_name")"
    target_path="$(trim_whitespace "$target_path")"

    if [ -z "$preset_name" ] || [ -z "$target_path" ]; then
      echo "Invalid toolchain preset line: $line" >&2
      return 1
    fi

    if is_selected_toolchain_preset "$preset_name"; then
      mark_toolchain_preset_found "$preset_name"
      register_toolchain_target "$preset_name" "$target_path"
    fi
  done < "$preset_file"
}

validate_toolchain_presets() {
  local preset

  for preset in "${TOOLCHAIN_PRESETS[@]}"; do
    if ! is_selected_toolchain_preset "$preset"; then
      continue
    fi
    if ! is_found_toolchain_preset "$preset"; then
      echo "Error: unknown toolchain preset '$preset'." >&2
      return 1
    fi
  done
}

is_found_toolchain_preset() {
  local preset="$1"
  local found

  for found in "${FOUND_TOOLCHAIN_PRESETS[@]}"; do
    if [ "$found" = "$preset" ]; then
      return 0
    fi
  done

  return 1
}

load_toolchain_targets() {
  local target_path

  expand_toolchain_preset_args
  load_toolchain_preset_file "$BUILTIN_TOOLCHAIN_PRESETS_FILE"
  load_toolchain_preset_file "$TOOLCHAIN_PRESETS_FILE"
  validate_toolchain_presets

  for target_path in "${TOOLCHAIN_PATH_ARGS[@]}"; do
    register_toolchain_target "cli" "$target_path"
  done
}

print_dry_run_command() {
  local title="$1"
  local one_line
  shift

  echo "$title"
  for arg in "$@"; do
    printf '%s\n' "$(printf '%q' "$arg")"
  done

  echo
  echo "One-line command (copy/paste):"
  one_line=$(build_one_line_command "$@")
  printf '%s\n' "$one_line"
}

build_one_line_command() {
  local one_line=""

  for arg in "$@"; do
    if [ -z "$one_line" ]; then
      one_line="$(printf '%q' "$arg")"
    else
      one_line="$one_line $(printf '%q' "$arg")"
    fi
  done

  printf '%s' "$one_line"
}

print_reentry_instructions() {
  local reentry_command shell_command

  reentry_command=$(build_one_line_command "${EXEC_CMD[@]}")
  printf 'Re-enter with: %s\n' "$reentry_command"

  if [ "$MODE" != "shell" ]; then
    shell_command=$(build_one_line_command "${SHELL_EXEC_CMD[@]}")
    printf 'Open a shell instead: %s\n' "$shell_command"
  fi

  printf 'Stop and remove with: docker rm -f %q\n' "$NAME"
}

build_toolchain_prepare_script() {
  local volume_name="$1"
  local toolchain_mount mount_volume subpath target_path source_name script

  script="set -euo pipefail"

  for toolchain_mount in "${TOOLCHAIN_VOLUME_MOUNTS[@]}"; do
    IFS='|' read -r mount_volume subpath target_path source_name <<<"$toolchain_mount"
    if [ "$mount_volume" != "$volume_name" ]; then
      continue
    fi

    script+=$'\n'
    script+="mkdir -p $(printf '%q' "$TOOLCHAIN_PREPARE_MOUNT_PATH/$subpath")"
  done

  printf '%s' "$script"
}

print_toolchain_prepare_commands() {
  local volume_name script
  local -a prepare_cmd

  for volume_name in "${TOOLCHAIN_SHARED_VOLUMES[@]}"; do
    script="$(build_toolchain_prepare_script "$volume_name")"
    prepare_cmd=(docker run --rm)
    if [ -n "$USER_SPEC" ]; then
      prepare_cmd+=(--user "$USER_SPEC")
    fi
    prepare_cmd+=(--mount "type=volume,src=${volume_name},dst=${TOOLCHAIN_PREPARE_MOUNT_PATH}" "$IMAGE" bash -lc "$script")
    print_dry_run_command "Dry run: toolchain prepare command for ${volume_name} (each arg on its own line, shell-escaped):" "${prepare_cmd[@]}"
    echo
  done
}

run_toolchain_prepare_commands() {
  local volume_name script
  local -a prepare_cmd

  for volume_name in "${TOOLCHAIN_SHARED_VOLUMES[@]}"; do
    script="$(build_toolchain_prepare_script "$volume_name")"
    prepare_cmd=(docker run --rm)
    if [ -n "$USER_SPEC" ]; then
      prepare_cmd+=(--user "$USER_SPEC")
    fi
    prepare_cmd+=(--mount "type=volume,src=${volume_name},dst=${TOOLCHAIN_PREPARE_MOUNT_PATH}" "$IMAGE" bash -lc "$script")
    "${prepare_cmd[@]}"
  done
}

# Build docker run command
if [ "$KEEP_CONTAINER_RUNNING" = true ]; then
  DOCKER_CMD=(docker run -d \
    --add-host=host.docker.internal:host-gateway \
    --name "$NAME")
else
  DOCKER_CMD=(docker run --rm -it \
    --add-host=host.docker.internal:host-gateway \
    --name "$NAME")
fi

# Add default mounts
DOCKER_CMD+=(
  -v "$HOME/.bun:${HOME_IN_CONTAINER}/.bun:rw" \
  -v "$PNPM_STORE_HOST:${HOME_IN_CONTAINER}/.pnpm-store:rw" \
  -v "$HOME/.cache/opencode:${HOME_IN_CONTAINER}/.cache/opencode:rw" \
  -v "$HOME/.local/state/opencode:${HOME_IN_CONTAINER}/.local/state/opencode:rw" \
  -v "$HOME/.local/share/opencode:${HOME_IN_CONTAINER}/.local/share/opencode:rw" \
  -v "$CONFIG_DIR:${HOME_IN_CONTAINER}/.config/opencode:rw" \
  -v "$HOME/.agents:${HOME_IN_CONTAINER}/.agents:rw" \
  -v "$HOME/.config/openspec:${HOME_IN_CONTAINER}/.config/openspec:rw" \
  -v "$PROJECT_HOST_PATH:$CONTAINER_PROJECT_PATH:rw" \
  -w "$CONTAINER_PROJECT_PATH"
)

load_toolchain_targets

echo "Place your global OpenCode config in $HOME/.config/opencode/opencode.json"
echo "Use global config for user-wide preferences like themes, providers, or keybinds."
echo ""
echo "Starting temporary container '$NAME' from image '$IMAGE'"
echo "  Project: $PROJECT_PATH -> $CONTAINER_WORKDIR"
echo "  Config:  $CONFIG_DIR -> ${HOME_IN_CONTAINER}/.config/opencode"
if [ ${#TOOLCHAIN_VOLUME_MOUNTS[@]} -gt 0 ]; then
  echo "  Toolchain cache mounts:"
  for toolchain_mount in "${TOOLCHAIN_VOLUME_MOUNTS[@]}"; do
    IFS='|' read -r volume_name subpath target_path source_name <<<"$toolchain_mount"
    echo "    $source_name: $volume_name:$subpath -> $target_path"
  done
else
  echo "  Toolchain cache mounts: disabled (no preset or toolchain path selected)"
fi
echo "  Forwarded env count: ${#ENV_ARGS[@]}"
echo ""

for toolchain_mount in "${TOOLCHAIN_VOLUME_MOUNTS[@]}"; do
  IFS='|' read -r volume_name subpath target_path source_name <<<"$toolchain_mount"
  DOCKER_CMD+=("--mount" "type=volume,src=${volume_name},dst=${target_path},volume-subpath=${subpath}")
done

# Append user mounts
for m in "${MOUNTS[@]}"; do
  mount_arg="$(process_mount "$m")"
  DOCKER_CMD+=("-v" "$mount_arg")
done

# Append env args
for arg in "${ENV_ARGS[@]}"; do
  DOCKER_CMD+=("$arg")
done

# Append port mappings (if any) before the image
for mapping in "${PORT_MAPPINGS[@]}"; do
  # Accept forms: ip:host:container, host:container, container
  case "$mapping" in
    *:*:*)
      # ip:host:container
      DOCKER_CMD+=("-p" "$mapping") ;;
    *:*)
      # host:container
      DOCKER_CMD+=("-p" "$mapping") ;;
    *)
      # single port -> map same port on host
      DOCKER_CMD+=("-p" "${mapping}:${mapping}") ;;
  esac
done

# Append network mode if provided
if [ -n "$NETWORK_MODE" ]; then
  DOCKER_CMD+=("--network" "$NETWORK_MODE")
fi

# Append env-file if specified
if [ -n "$ENV_FILE" ]; then
  DOCKER_CMD+=("--env-file" "$ENV_FILE")
fi

if [ -n "$USER_SPEC" ]; then
  DOCKER_CMD+=("--user" "$USER_SPEC")
fi

EXEC_CMD=()
SHELL_EXEC_CMD=()
RUNTIME_CMD=()

case "$MODE" in
  opencode)
    RUNTIME_CMD=(opencode)
    ;;
  web)
    RUNTIME_CMD=(opencode web)
    ;;
  shell)
    RUNTIME_CMD=(bash)
    ;;
  *)
    echo "Unknown mode: $MODE (expected: opencode, web, shell)" >&2
    exit 1
    ;;
esac

if [ "$MODE" = "opencode" ] || [ "$MODE" = "web" ]; then
  RUNTIME_CMD+=("${OPENCODE_ARGS[@]}")
fi

if [ "$KEEP_CONTAINER_RUNNING" = true ]; then
  DOCKER_CMD+=("$IMAGE" sleep infinity)
  EXEC_CMD=(docker exec -it -w "$CONTAINER_PROJECT_PATH")
  SHELL_EXEC_CMD=(docker exec -it -w "$CONTAINER_PROJECT_PATH")

  if [ -n "$USER_SPEC" ]; then
    EXEC_CMD+=("-u" "$USER_SPEC")
    SHELL_EXEC_CMD+=("-u" "$USER_SPEC")
  fi

  EXEC_CMD+=("$NAME" /usr/local/bin/opencode-load-env)
  SHELL_EXEC_CMD+=("$NAME" /usr/local/bin/opencode-load-env bash)

  EXEC_CMD+=("${RUNTIME_CMD[@]}")
else
  DOCKER_CMD+=("$IMAGE" "${RUNTIME_CMD[@]}")
fi

# If dry run, print final command and exit
if [ "$DRY_RUN" = true ]; then
  if [ ${#TOOLCHAIN_SHARED_VOLUMES[@]} -gt 0 ]; then
    print_toolchain_prepare_commands
  fi

  if [ "$KEEP_CONTAINER_RUNNING" = true ]; then
    print_dry_run_command "Dry run: detached keepalive container command (each arg on its own line, shell-escaped):" "${DOCKER_CMD[@]}"
    echo
    print_dry_run_command "Dry run: interactive session command (each arg on its own line, shell-escaped):" "${EXEC_CMD[@]}"
  else
    print_dry_run_command "Dry run: final docker command (each arg on its own line, shell-escaped):" "${DOCKER_CMD[@]}"
  fi
  exit 0
fi

if [ "$KEEP_CONTAINER_RUNNING" = true ]; then
  echo "Keep-running mode enabled: container '$NAME' will remain running after you exit the session."

  if [ ${#TOOLCHAIN_SHARED_VOLUMES[@]} -gt 0 ]; then
    run_toolchain_prepare_commands
  fi

  CONTAINER_ID=$("${DOCKER_CMD[@]}")
  echo "Started keepalive container '$NAME' (${CONTAINER_ID})."
  print_reentry_instructions
  echo ""

  set +e
  "${EXEC_CMD[@]}"
  EXEC_STATUS=$?
  set -e

  echo ""
  echo "Session exited. Container '$NAME' is still running."
  print_reentry_instructions
  exit "$EXEC_STATUS"
fi

# Execute
if [ ${#TOOLCHAIN_SHARED_VOLUMES[@]} -gt 0 ]; then
  run_toolchain_prepare_commands
fi

"${DOCKER_CMD[@]}"
