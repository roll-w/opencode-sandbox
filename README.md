# OpenCode Sandbox

OpenCode Sandbox provides a lightweight container-based environment for running the OpenCode project and related tooling in an isolated, reproducible container.

It bundles a small developer image (see `container/Containerfile`) with common tools installed so you can quickly open a workspace, run the OpenCode CLI, and iterate on projects without polluting your host environment.

## Quick Start

- Run with the provided helper script (recommended):

  ```bash
  ./start.sh
  ```

  The script will start a temporary container using the default image `ghcr.io/roll-w/opencode-sandbox:main`, mount your project (current directory by default)
  into the container, forward `OPENCODE_*` environment variables by default, and drop you into the container as the `opencode` user.

- Dry run to inspect the generated docker command without running it:

  ```bash
  ./start.sh --dry-run /path/to/your/project
  ```

- Run the published image directly with Docker (basic):

  ```bash
  docker run --rm -it -v "$(pwd):/workspace" ghcr.io/roll-w/opencode-sandbox:main
  ```

## Build

If you want to build the container image locally from `container/Containerfile`:

```bash
# Build locally with Docker
docker build -f container/Containerfile \
  --build-arg UBUNTU_VERSION=24.04 \
  --build-arg USER_UID=$(id -u) \
  --build-arg USER_GID=$(id -g) \
  -t opencode-sandbox:local .

# Or with podman
podman build -f container/Containerfile -t opencode-sandbox:local .
```

Notes:
- The `USER_UID` and `USER_GID` build args ensure files created in the container are owned by your host user.
- You can change `UBUNTU_VERSION` or tag as you like.

## Included tools

The image installs a curated set of developer tooling useful for OpenCode development:

- Node.js (via NodeSource) and global `pnpm` (store configured)
- OpenJDK 17, Python 3 (venv, pip), build-essential, git, jq, curl, wget

See `container/Containerfile` for the full list and exact versions.

## Development workflow

1. Start a container with your project mounted (`./start.sh /path/to/project`).
2. Inside the container you can run OpenCode commands, install dependencies, or run builds without configuring your host.
3. Use additional `./start.sh -m host:path:container_path[:ro|rw]` to bind extra mounts, or `-E KEY=VAL` to pass extra environment variables.

The helper script automatically:
- Creates a predictable container path for your project so paths inside the container mirror the host path.
- Forwards `OPENCODE_*` environment variables from your host unless `--no-auto-forward` is given.
- Maps common caches and config directories (`~/.config/opencode`, pnpm store, cache directories) into the container for persistence.

## Examples

- Start container and open the default OpenCode CLI as the `opencode` user (recommended):

  ```bash
  ./start.sh /path/to/project
  ```

- Start with a custom image:

  ```bash
  ./start.sh -i ghcr.io/roll-w/opencode-sandbox:main /path/to/project
  ```

- Add an extra bind mount (read-only):

  ```bash
  ./start.sh -m "/host/extra:/container/extra:ro" /path/to/project
  ```

- Pass an env var into the container:

  ```bash
  ./start.sh -E MY_VAR=1 /path/to/project
  ```

## Proxies and networking

- The script accepts `-p/--http-proxy`, `--https-proxy`, and `--no-proxy` to forward proxy settings into the container.
- localhost/127.0.0.1 in proxy hostnames are translated to `host.docker.internal` so the container can reach host services.

## Contributing

- Fork the repository and open a pull request for changes.

## License

```text
MIT License

Copyright (c) 2026 RollW

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
