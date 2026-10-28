#!/usr/bin/env bash
# Build the devcontainer image locally from .devcontainer/Dockerfile.
# Runs on the HOST via devcontainer.json "initializeCommand", before the container starts.
set -euo pipefail

IMAGE="${DEVCONTAINER_IMAGE:-local/devcontainer-data:latest}"
DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$DIR/export-host-certs.sh"
docker build -f "$DIR/Dockerfile" -t "$IMAGE" "$DIR/.."
