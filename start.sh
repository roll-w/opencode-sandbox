#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [options] [project_path]

Options:
  -i, --image IMAGE         Docker image to use (overrides auto-detection)
  -c, --config DIR          Config directory (default: ~/.config/opencode)
  -n, --name NAME           Container name (default: opencode-temp)
  -w, --workdir DIR         Container working dir (default: /workspace/project)
  -p, --http-proxy URL      HTTP proxy to pass into container
      --https-proxy URL     HTTPS proxy to pass into container
      --no-proxy LIST       Comma-separated no_proxy list
  -m, --mount HOST:CONTAINER[:ro|rw]
                            Additional mount (repeatable). HOST may be relative; CONTAINER
                            may be absolute or relative to the container workdir.
      --dry-run             Print the final docker command and exit without running it
  -E, --env KEY=VAL         Pass an environment variable into the container (may repeat)
      --env-file FILE       Pass an env file to docker (each line VAR=VAL)
      --no-auto-forward    Do not automatically forward host OPENCODE_* env vars
  -h, --help                Show this help

Place your global OpenCode config in ~/.config/opencode/opencode.json.
Use global config for user-wide preferences like themes, providers, or keybinds.

Examples:
  $0
  $0 -i ghcr.io/roll-w/opencode-sandbox:main /path/to/project
  $0 --config ~/.config/opencode
  $0 -p http://proxy:3128 -E OPENCODE_DISABLE_LSP_DOWNLOAD=false
EOF
}

# Defaults
IMAGE=""
PROJECT_PATH=""
CONFIG_DIR=""
CONTAINER_WORKDIR="/workspace"
NAME="opencode-temp"

# Proxy defaults (empty by default; only set when provided)
HTTP_PROXY_DEFAULT=""
HTTPS_PROXY_DEFAULT=""
NO_PROXY_DEFAULT=""

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
DRY_RUN=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)
      IMAGE="$2"; shift 2 ;;
    -c|--config)
      CONFIG_DIR="$2"; shift 2 ;;
    -n|--name)
      NAME="$2"; shift 2 ;;
    -w|--workdir)
      CONTAINER_WORKDIR="$2"; shift 2 ;;
    -m|--mount)
      # Accept mounts like host:container or host:container:ro
      MOUNTS+=("$2"); shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -p|--http-proxy)
      HTTP_PROXY="$2"; shift 2 ;;
    --https-proxy)
      HTTPS_PROXY="$2"; shift 2 ;;
    --no-proxy)
      NO_PROXY="$2"; shift 2 ;;
    -E|--env)
      ENV_ARGS+=("-e" "$2"); shift 2 ;;
    --env-file)
      ENV_FILE="$2"; shift 2 ;;
    --no-auto-forward)
      AUTO_FORWARD_OPENCODE=false; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
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

NAME="opencode-$(date +%s)"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: Project path '$PROJECT_PATH' does not exist or is not a directory." >&2
  exit 1
fi
mkdir -p "$CONFIG_DIR"

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

# Default OpenCode-specific env fallback
OPENCODE_DISABLE_LSP_DOWNLOAD="${OPENCODE_DISABLE_LSP_DOWNLOAD:-true}"
ENV_ARGS+=("-e" "OPENCODE_DISABLE_LSP_DOWNLOAD=$OPENCODE_DISABLE_LSP_DOWNLOAD")

echo "Place your global OpenCode config in $HOME/.config/opencode/opencode.json"
echo "Use global config for user-wide preferences like themes, providers, or keybinds."

echo "Starting temporary container '$NAME' from image '$IMAGE'"
echo "  Project: $PROJECT_PATH -> $CONTAINER_WORKDIR"
echo "  Config:  $CONFIG_DIR -> /home/opencode/.config/opencode"
echo "  Forwarded env count: ${#ENV_ARGS[@]}"
echo ""

# Compute container mount path: preserve host path under container workdir
# Make PROJECT_PATH absolute (canonicalize) to build a predictable container path
PROJECT_HOST_PATH="$(cd "$PROJECT_PATH" && pwd)"
# Remove any trailing slash from CONTAINER_WORKDIR to avoid double slashes
CONTAINER_WORKDIR="${CONTAINER_WORKDIR%/}"
CONTAINER_PROJECT_PATH="$CONTAINER_WORKDIR$PROJECT_HOST_PATH"

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
  # Resolve container_path under container workdir when relative
  if [[ "$container_path" != /* ]]; then
    container_path="$CONTAINER_WORKDIR$container_path"
  fi
  # Output the mount spec only (host:container:mode). Caller will add the -v flag separately.
  printf '%s' "$host_path:$container_path:$mode"
}

# Build docker run command
DOCKER_CMD=(docker run --rm -it \
  --add-host=host.docker.internal:host-gateway \
  --name "$NAME")

# Add default mounts
DOCKER_CMD+=(
  -v "$HOME/.bun:/home/opencode/.bun:rw" \
  -v "$HOME/.pnpm-store:/home/opencode/.pnpm-store:rw" \
  -v "$HOME/.cache/opencode:/home/opencode/.cache/opencode:rw" \
  -v "$HOME/.local/state/opencode:/home/opencode/.local/state/opencode:rw" \
  -v "$HOME/.local/share/opencode:/home/opencode/.local/share/opencode:rw" \
  -v "$HOME/.config/opencode:/home/opencode/.config/opencode:rw" \
  -v "$PROJECT_HOST_PATH:$CONTAINER_PROJECT_PATH:rw" \
  -w "$CONTAINER_PROJECT_PATH"
)

# Append user mounts
for m in "${MOUNTS[@]}"; do
  mount_arg="$(process_mount "$m")"
  DOCKER_CMD+=("-v" "$mount_arg")
done

# Append env args
for arg in "${ENV_ARGS[@]}"; do
  DOCKER_CMD+=("$arg")
done

# Append env-file if specified
if [ -n "$ENV_FILE" ]; then
  DOCKER_CMD+=("--env-file" "$ENV_FILE")
fi

# Append image and command
DOCKER_CMD+=("$IMAGE" opencode)

# If dry run, print final command and exit
if [ "$DRY_RUN" = true ]; then
  echo "Dry run: final docker command (each arg on its own line, shell-escaped):"
  for arg in "${DOCKER_CMD[@]}"; do
    printf '%s\n' "$(printf '%q' "$arg")"
  done
  echo
  echo "One-line command (copy/paste):"
  # Build one-line safely by joining escaped args
  one_line=""
  for arg in "${DOCKER_CMD[@]}"; do
    if [ -z "$one_line" ]; then
      one_line="$(printf '%q' "$arg")"
    else
      one_line="$one_line $(printf '%q' "$arg")"
    fi
  done
  printf '%s\n' "$one_line"
  exit 0
fi

# Execute
"${DOCKER_CMD[@]}"
