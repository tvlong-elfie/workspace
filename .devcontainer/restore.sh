#!/usr/bin/env bash
# Restore an elfie devcontainer backup made by backup.sh into the named Docker volumes.
#
# Run this on the HOST with the devcontainer stopped.
#
# Usage:
#   .devcontainer/restore.sh gs://BUCKET/devcontainer-backups/USER/elfie/TS/elfie-devcontainer.tar.gpg --project PROJECT
#   .devcontainer/restore.sh ./elfie-devcontainer-TS.tar.gpg
#   [--volume-suffix -restoretest]   restore into <vol>-restoretest instead of the real volumes
#
# Passphrase: taken from $BACKUP_PASSPHRASE, otherwise gpg prompts for it.
# Container-layer files (zsh history etc.) are extracted to ./elfie-container-home-TS/;
# copy them into the rebuilt container yourself.
set -euo pipefail

HELPER_IMAGE=alpine:3.20
WORKSPACE_FOLDER="$(cd "$(dirname "$0")/.." && pwd)"

SRC="" PROJECT="" SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --volume-suffix) SUFFIX="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) SRC="$1"; shift ;;
  esac
done
[[ -n "$SRC" ]] || { echo "missing backup source" >&2; exit 2; }

if [[ -z "$SUFFIX" ]] && [[ -n "$(docker ps -q --filter "label=devcontainer.local_folder=$WORKSPACE_FOLDER")" ]]; then
  echo "devcontainer is running; stop it before restoring into live volumes" >&2; exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ "$SRC" == gs://* ]]; then
  [[ -n "$PROJECT" ]] || { echo "--project is required for gs:// sources" >&2; exit 2; }
  gcloud storage cp --project "$PROJECT" "$SRC" "$WORK/backup.tar.gpg"
else
  cp "$SRC" "$WORK/backup.tar.gpg"
fi

echo "==> Decrypting"
if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then
  read -rsp "Backup passphrase: " BACKUP_PASSPHRASE; echo
fi
gpg --batch --pinentry-mode loopback --passphrase-fd 3 --decrypt "$WORK/backup.tar.gpg" 3<<<"$BACKUP_PASSPHRASE" \
  | tar xf - -C "$WORK"
STAGE="$(find "$WORK" -maxdepth 1 -type d -name 'elfie-devcontainer-*' | head -n1)"
cat "$STAGE/MANIFEST"

echo "==> Restoring volumes"
for archive in "$STAGE"/volumes/*.tgz; do
  vol="$(basename "$archive" .tgz)$SUFFIX"
  docker volume create "$vol" >/dev/null
  docker run --rm -v "$vol":/dst -v "$STAGE/volumes":/in:ro "$HELPER_IMAGE" sh -c "
    find /dst -mindepth 1 -delete &&
    tar xzpf /in/$(basename "$archive") --numeric-owner -C /dst"
  echo "    $vol"
done
SSH_VOL="elfie-ssh$SUFFIX"
if docker volume inspect "$SSH_VOL" >/dev/null 2>&1; then
  docker run --rm -v "$SSH_VOL":/dst "$HELPER_IMAGE" sh -c \
    'chmod 700 /dst; for k in /dst/id_*; do case "$k" in *.pub) ;; *) [ -f "$k" ] && chmod 600 "$k";; esac; done'
fi

if [[ -f "$STAGE/container-home/home.tgz" ]]; then
  OUT="$PWD/elfie-container-home-$(basename "$STAGE" | sed 's/elfie-devcontainer-//')"
  mkdir -p "$OUT"
  tar xzpf "$STAGE/container-home/home.tgz" -C "$OUT"
  echo "==> Container-layer files extracted to $OUT"
  echo "    After the container is up: docker cp $OUT/. <container>:/home/vscode/"
fi
echo "==> Done"
