#!/usr/bin/env bash
# Export the Netskope TLS-inspection CA chain from the macOS keychain so the
# devcontainer image can trust it. Runs on the HOST as devcontainer.json's initializeCommand.
#
# Writes .devcontainer/certs/netskope.crt. On hosts without Netskope (or non-macOS)
# it writes nothing and the image build just skips the extra CA.
set -euo pipefail

OUT_DIR="$(cd "$(dirname "$0")" && pwd)/certs"
OUT="$OUT_DIR/netskope.crt"
mkdir -p "$OUT_DIR"
rm -f "$OUT"

command -v security >/dev/null 2>&1 || exit 0

# Netskope's root (*.sin2.goskope.com) and tenant intermediate (ca.elfie.goskope.com).
for kc in /Library/Keychains/System.keychain "$HOME/Library/Keychains/login.keychain-db"; do
  [[ -f "$kc" ]] && security find-certificate -a -c goskope -p "$kc" 2>/dev/null >> "$OUT" || true
done

if [[ -s "$OUT" ]]; then
  echo "Exported $(grep -c 'BEGIN CERTIFICATE' "$OUT") Netskope CA cert(s) to $OUT"
else
  rm -f "$OUT"
fi
