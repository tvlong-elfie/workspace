#!/usr/bin/env bash
# Back up the elfie dev pod's home state into a gpg-encrypted archive and optionally
# upload it to GCS. Runs on the HOST; the dev pod must be running.
#
# Usage:
#   k8s/dev/backup.sh --bucket BUCKET --project PROJECT [--no-upload] [--keep-local]
#
# Passphrase: taken from $BACKUP_PASSPHRASE, otherwise prompted.
# Output:     gs://BUCKET/dev-backups/$USER/elfie/<timestamp>/elfie-dev.tar.gpg
set -euo pipefail

# Home paths that hold state. The PVC-backed ones survive pod recreation; the rest live in
# the pod's writable layer and are only captured here.
HOME_PATHS=(.claude .config/gcloud .config/gh .ssh .zsh_history .aif .dagster .copilot)
DEPLOYMENT=elfie-dev

BUCKET="" PROJECT="" UPLOAD=1 KEEP_LOCAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --no-upload) UPLOAD=0; KEEP_LOCAL=1; shift ;;
    --keep-local) KEEP_LOCAL=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ $UPLOAD -eq 1 && ( -z "$BUCKET" || -z "$PROJECT" ) ]]; then
  echo "--bucket and --project are required (or pass --no-upload)" >&2; exit 2
fi

POD="$(kubectl get pod -l app=$DEPLOYMENT -o jsonpath='{.items[0].metadata.name}')"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
STAGE="$WORK/elfie-dev-$TS"
mkdir -p "$STAGE"
trap 'rm -rf "$WORK"' EXIT

echo "==> Archiving home paths from pod $POD"
# --ignore-failed-read skips paths that don't exist yet instead of failing the archive.
kubectl exec "$POD" -- tar czf - --numeric-owner --ignore-failed-read -C /home/vscode "${HOME_PATHS[@]}" \
  > "$STAGE/home.tgz"
echo "    $(du -h "$STAGE/home.tgz" | cut -f1) from ${HOME_PATHS[*]}"

cat > "$STAGE/MANIFEST" <<EOF
created_utc=$TS
host=$(hostname)
user=$USER
pod=$POD
home_paths=${HOME_PATHS[*]}
EOF

echo "==> Encrypting (gpg AES256)"
OUT="$WORK/elfie-dev.tar.gpg"
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
  DEST="gs://$BUCKET/dev-backups/$USER/elfie/$TS/"
  echo "==> Uploading to $DEST"
  gcloud storage cp --project "$PROJECT" "$OUT" "$DEST"
fi

if [[ $KEEP_LOCAL -eq 1 ]]; then
  LOCAL="$PWD/elfie-dev-$TS.tar.gpg"
  mv "$OUT" "$LOCAL"
  chmod 600 "$LOCAL"
  echo "==> Local copy: $LOCAL"
fi
echo "==> Done"
