#!/usr/bin/env bash
# Back up the elfie devcontainer's state (named volumes plus a few container-layer
# files) into a gpg-encrypted archive and upload it to GCS.
#
# Run this on the HOST (macOS), not inside the devcontainer.
#
# Usage:
#   .devcontainer/backup.sh --bucket BUCKET --project PROJECT [--no-upload] [--keep-local]
#
# Passphrase: taken from $BACKUP_PASSPHRASE, otherwise gpg prompts for it.
# Output:     gs://BUCKET/devcontainer-backups/$USER/elfie/<timestamp>/elfie-devcontainer.tar.gpg
set -euo pipefail

VOLUMES=(elfie-claude elfie-gcloud elfie-gh elfie-ssh)
# Paths in the container's writable layer. A rebuild loses these because they aren't in a volume.
CONTAINER_PATHS=(.zsh_history .aif .dagster .copilot)
WORKSPACE_FOLDER="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_IMAGE=alpine:3.20

BUCKET="" PROJECT="" UPLOAD=1 KEEP_LOCAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --no-upload) UPLOAD=0; KEEP_LOCAL=1; shift ;;
    --keep-local) KEEP_LOCAL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ $UPLOAD -eq 1 && ( -z "$BUCKET" || -z "$PROJECT" ) ]]; then
  echo "--bucket and --project are required (or pass --no-upload)" >&2; exit 2
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
STAGE="$WORK/elfie-devcontainer-$TS"
mkdir -p "$STAGE/volumes" "$STAGE/container-home"
trap 'rm -rf "$WORK"' EXIT

echo "==> Archiving volumes"
for vol in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "    skip $vol (not found)"; continue
  fi
  docker run --rm -v "$vol":/src:ro -v "$STAGE/volumes":/out "$HELPER_IMAGE" \
    tar czf "/out/$vol.tgz" --numeric-owner -C /src .
  echo "    $vol -> $(du -h "$STAGE/volumes/$vol.tgz" | cut -f1)"
done

CID="$(docker ps -q --filter "label=devcontainer.local_folder=$WORKSPACE_FOLDER" | head -n1)"
if [[ -n "$CID" ]]; then
  echo "==> Archiving container-layer files from $CID"
  existing=()
  for p in "${CONTAINER_PATHS[@]}"; do
    docker exec "$CID" test -e "/home/vscode/$p" && existing+=("$p")
  done
  if [[ ${#existing[@]} -gt 0 ]]; then
    docker exec "$CID" tar czf - --numeric-owner -C /home/vscode "${existing[@]}" \
      > "$STAGE/container-home/home.tgz"
    echo "    ${existing[*]}"
  fi
else
  echo "==> Devcontainer not running; skipping container-layer files"
fi

cat > "$STAGE/MANIFEST" <<EOF
created_utc=$TS
host=$(hostname)
user=$USER
workspace=$WORKSPACE_FOLDER
volumes=${VOLUMES[*]}
container_paths=${CONTAINER_PATHS[*]}
EOF

echo "==> Encrypting (gpg AES256)"
OUT="$WORK/elfie-devcontainer.tar.gpg"
# gpg's pinentry can't prompt while stdin is the tar pipe, so ask for the passphrase here.
if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then
  read -rsp "Backup passphrase: " BACKUP_PASSPHRASE; echo
  read -rsp "Confirm passphrase: " confirm; echo
  [[ "$BACKUP_PASSPHRASE" == "$confirm" ]] || { echo "passphrases do not match" >&2; exit 1; }
  [[ -n "$BACKUP_PASSPHRASE" ]] || { echo "empty passphrase" >&2; exit 1; }
fi
tar cf - -C "$WORK" "$(basename "$STAGE")" \
  | gpg --batch --pinentry-mode loopback --passphrase-fd 3 \
      --symmetric --cipher-algo AES256 --output "$OUT" 3<<<"$BACKUP_PASSPHRASE"

if [[ $UPLOAD -eq 1 ]]; then
  DEST="gs://$BUCKET/devcontainer-backups/$USER/elfie/$TS/"
  echo "==> Uploading to $DEST"
  gcloud storage cp --project "$PROJECT" "$OUT" "$DEST"
fi

if [[ $KEEP_LOCAL -eq 1 ]]; then
  LOCAL="$PWD/elfie-devcontainer-$TS.tar.gpg"
  mv "$OUT" "$LOCAL"
  chmod 600 "$LOCAL"
  echo "==> Local copy: $LOCAL"
fi
echo "==> Done"
