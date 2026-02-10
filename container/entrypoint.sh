#!/usr/bin/env bash

set -euo pipefail

CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

# Non-root mode: try to adapt opencode user to current UID/GID for home path compatibility
if [ "$CURRENT_UID" -ne 0 ]; then
  OPENCODE_UID=$(id -u opencode 2>/dev/null || echo "")
  if [ "$CURRENT_UID" != "$OPENCODE_UID" ]; then
    # Try to modify via sudo (silent failure if no permission)
    if sudo -n true 2>/dev/null; then
      sudo groupmod -g "$CURRENT_GID" opencode 2>/dev/null || true
      sudo usermod -u "$CURRENT_UID" opencode 2>/dev/null || true
    fi
  fi
  export HOME=/home/opencode
fi

# Configure pnpm store directory based on user
if [ "$CURRENT_UID" -eq 0 ]; then
  pnpm config set store-dir /root/.pnpm-store --global 2>/dev/null || true
else
  pnpm config set store-dir /home/opencode/.pnpm-store --global 2>/dev/null || true
fi

# Show helpful environment info
echo "Opencode sandbox ready"
echo "User: $(whoami 2>/dev/null || id -un 2>/dev/null || echo "uid=$CURRENT_UID")"
echo "UID: $CURRENT_UID  GID: $CURRENT_GID"
echo "Workspace: $(pwd)"
echo ""

# If first argument is provided, execute it. Otherwise, run interactive shell.
if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec bash
fi
