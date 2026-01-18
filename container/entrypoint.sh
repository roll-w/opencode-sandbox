#!/usr/bin/env bash

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

mkdir -p /workspace /home/opencode/.config/opencode /home/opencode/.local/share/opencode \
  /home/opencode/.local/state/opencode /home/opencode/.cache/opencode /home/opencode/.bun /home/opencode/.pnpm-store

# Show helpful environment info
echo "Opencode sandbox ready"
echo "User: $(whoami) UID: $(id -u) GID: $(id -g)"
echo "Workspace: $(pwd)"
echo ""

# If first argument is provided, execute it. Otherwise, run interactive shell.
if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec bash
fi
