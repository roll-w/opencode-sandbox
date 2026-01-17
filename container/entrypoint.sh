#!/usr/bin/env bash
# Entrypoint for opencode sandbox container
# Usage: docker run --rm -it \
#   -v /path/to/project:/workspace/project \
#   -v /path/to/config:/workspace/config \
#   -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
#   lampray/opencode-sandbox:latest

set -euo pipefail

# If container started as root (build-time), switch to opencode
if [ "$(id -u)" -eq 0 ] && [ -n "${HOST_UID-}" ]; then
  # Create user with host uid/gid if differs
  if ! id -u opencode >/dev/null 2>&1; then
    addgroup --gid "${HOST_GID-1000}" opencode || true
    adduser --disabled-password --gecos "" --uid "${HOST_UID-1000}" --gid "${HOST_GID-1000}" opencode || true
  fi
  exec su - opencode -c "$*"
fi

# Show helpful environment info
echo "Opencode sandbox ready"
echo "User: $(whoami) UID: $(id -u) GID: $(id -g)"
echo "Workspace: $(pwd)"

# Print installed versions for convenience
java -version 2>&1 | sed -n '1,2p' || true
node -v || true
npm -v || true
pnpm -v || true
python3 --version || true
pip3 --version || true
jq --version || true

# If first argument is provided, execute it. Otherwise, run interactive shell.
if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec bash
fi
