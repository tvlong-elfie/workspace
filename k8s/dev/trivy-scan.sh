#!/usr/bin/env bash
# Scan the dev image with Trivy: the Dockerfile for misconfigurations, then the image that
# is loaded into minikube for OS/language vulnerabilities and leaked secrets. Runs on the HOST.
#
# Usage: k8s/dev/trivy-scan.sh [extra trivy image args...]
#   e.g. k8s/dev/trivy-scan.sh --ignore-unfixed --format json -o trivy.json
#
# Env:
#   DEV_IMAGE        image to scan (default: local/elfie-dev:latest)
#   TRIVY_SEVERITY   severities to report (default: HIGH,CRITICAL)
#   TRIVY_EXIT_CODE  exit code when findings exist (default: 0; set 1 to fail CI)
set -euo pipefail

IMAGE="${DEV_IMAGE:-local/elfie-dev:latest}"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
EXIT_CODE="${TRIVY_EXIT_CODE:-0}"
DIR="$(cd "$(dirname "$0")" && pwd)"

command -v trivy >/dev/null 2>&1 || {
  echo "trivy not found. Install it: brew install trivy (see https://trivy.dev)" >&2
  exit 127
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

minikube image ls | grep -qF "$IMAGE" || {
  echo "$IMAGE is not in minikube. Run k8s/dev/setup.sh first." >&2
  exit 1
}

status=0

echo "==> Misconfiguration scan: $DIR/Dockerfile"
trivy config --severity "$SEVERITY" --exit-code "$EXIT_CODE" "$DIR/Dockerfile" || status=$?

echo "==> Exporting $IMAGE from minikube"
minikube image save "$IMAGE" "$WORK/image.tar"

echo "==> Vulnerability + secret scan: $IMAGE"
trivy image --input "$WORK/image.tar" --scanners vuln,secret --severity "$SEVERITY" \
  --exit-code "$EXIT_CODE" "$@" || status=$?

exit "$status"
