#!/usr/bin/env bash
# Scan the devcontainer with Trivy: the Dockerfile for misconfigurations, then the built
# image for OS/language vulnerabilities and leaked secrets. Runs on the HOST.
#
# Usage: .devcontainer/trivy-scan.sh [extra trivy image args...]
#   e.g. .devcontainer/trivy-scan.sh --ignore-unfixed --format json -o trivy.json
#
# Env:
#   DEVCONTAINER_IMAGE  image to scan (default: local/devcontainer-data:latest)
#   TRIVY_SEVERITY      severities to report (default: HIGH,CRITICAL)
#   TRIVY_EXIT_CODE     exit code when findings exist (default: 0; set 1 to fail CI)
#   BUILD=1             rebuild the image via build-image.sh before scanning
set -euo pipefail

IMAGE="${DEVCONTAINER_IMAGE:-local/devcontainer-data:latest}"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
EXIT_CODE="${TRIVY_EXIT_CODE:-0}"
DIR="$(cd "$(dirname "$0")" && pwd)"

command -v trivy >/dev/null 2>&1 || {
  echo "trivy not found. Install it: brew install trivy (see https://trivy.dev)" >&2
  exit 127
}

if [[ "${BUILD:-0}" == "1" ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Building $IMAGE"
  bash "$DIR/build-image.sh"
fi

status=0

echo "==> Misconfiguration scan: $DIR/Dockerfile"
trivy config --severity "$SEVERITY" --exit-code "$EXIT_CODE" "$DIR/Dockerfile" || status=$?

echo "==> Vulnerability + secret scan: $IMAGE"
trivy image --scanners vuln,secret --severity "$SEVERITY" --exit-code "$EXIT_CODE" "$@" "$IMAGE" || status=$?

exit "$status"
