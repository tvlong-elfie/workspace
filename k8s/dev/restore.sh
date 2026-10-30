#!/usr/bin/env bash
# Restore an elfie dev pod backup made by backup.sh into the running pod's home directory.
# Runs on the HOST; the dev pod must be running.
#
# Usage:
#   k8s/dev/restore.sh gs://BUCKET/dev-backups/USER/elfie/TS/elfie-dev.tar.gpg --project PROJECT
#   k8s/dev/restore.sh ./elfie-dev-TS.tar.gpg
#
# Passphrase: taken from $BACKUP_PASSPHRASE, otherwise prompted.
set -euo pipefail

DEPLOYMENT=elfie-dev

SRC="" PROJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) SRC="$1"; shift ;;
  esac
done
[[ -n "$SRC" ]] || { echo "missing backup source" >&2; exit 2; }

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
STAGE="$(find "$WORK" -maxdepth 1 -type d -name 'elfie-dev-*' | head -n1)"
cat "$STAGE/MANIFEST"

POD="$(kubectl get pod -l app=$DEPLOYMENT -o jsonpath='{.items[0].metadata.name}')"
echo "==> Restoring into pod $POD:/home/vscode"
# -m skips mtimes: the PVC mount roots are root-owned, so tar can't set their timestamps.
kubectl exec -i "$POD" -- tar xzpmf - --numeric-owner -C /home/vscode < "$STAGE/home.tgz"

# Tar restores modes from the archive; tighten the ssh dir and private keys like the entrypoint expects.
kubectl exec "$POD" -- sh -c \
  'chmod 700 /home/vscode/.ssh 2>/dev/null; for k in /home/vscode/.ssh/id_*; do case "$k" in *.pub) ;; *) [ -f "$k" ] && chmod 600 "$k";; esac; done' || true
echo "==> Done"
