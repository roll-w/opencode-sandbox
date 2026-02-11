#!/usr/bin/env bash

set -euo pipefail

pnpm config set store-dir "${HOME}/.pnpm-store" --global 2>/dev/null || true

CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

echo "Opencode sandbox ready"
echo "UID: $CURRENT_UID  GID: $CURRENT_GID"
echo "HOME: $HOME"
echo "Workspace: $(pwd)"
echo ""

# If first argument is provided, execute it. Otherwise, run interactive shell.
if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec bash
fi
