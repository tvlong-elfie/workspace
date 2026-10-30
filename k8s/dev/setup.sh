#!/usr/bin/env bash
# Start a minikube cluster (vfkit driver, no Docker), build the dev image into it,
# and deploy the elfie dev pod. Runs on the HOST. This is the only dev environment setup.
#
# Usage: k8s/dev/setup.sh [path/to/public_key.pub]
#   Default public key: ~/.ssh/id_ed25519.pub
#
# Env:
#   K8S_VERSION  Kubernetes version to pin, match your cloud (default: minikube's default)
#   CPUS         default 6
#   MEMORY       MB, default 12288
#   DISK_SIZE    VM disk, default 100g (only applies when the cluster is created)
#
# One command from zero to a VS Code window on the pod. After the deploy it also writes the
# "elfie-dev" SSH alias, trusts the pod's host key (fingerprint checked), installs the VS Code
# Remote-SSH extension, and opens /workspaces/elfie. Connect later with: ssh elfie-dev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBKEY="${1:-$HOME/.ssh/id_ed25519.pub}"
K8S_VERSION="${K8S_VERSION:-}"
CPUS="${CPUS:-6}"
MEMORY="${MEMORY:-12288}"
DISK_SIZE="${DISK_SIZE:-100g}"

[[ -f "$PUBKEY" ]] || { echo "public key not found: $PUBKEY" >&2; exit 1; }

if ! minikube status >/dev/null 2>&1; then
  echo "==> Starting minikube"
  start_args=(--driver=vfkit --container-runtime=containerd --cpus="$CPUS" --memory="$MEMORY"
    --disk-size="$DISK_SIZE" --mount --mount-string="$ROOT:/host-elfie")
  [[ -n "$K8S_VERSION" ]] && start_args+=(--kubernetes-version="$K8S_VERSION")
  minikube start "${start_args[@]}"
fi

echo "==> Exporting host CA certs (Netskope, if present)"
bash "$ROOT/k8s/dev/export-host-certs.sh"

echo "==> Building dev image"
# minikube image build copies the whole build context into the VM, so stage only the files
# the Dockerfile copies. Sending the repo would add gigabytes per build.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/k8s/dev"
cp -R "$ROOT/k8s/dev/Dockerfile" "$ROOT/k8s/dev/entrypoint.sh" "$ROOT/k8s/dev/certs" "$stage/k8s/dev/"
build_log="$(mktemp)"
minikube image build -t local/elfie-dev:latest -f k8s/dev/Dockerfile "$stage" 2>&1 | tee "$build_log"
# minikube image build exits 0 even when the build fails, so check the log for the build error.
if grep -q '^error:' "$build_log"; then
  echo "Image build failed; not deploying the old image." >&2
  rm -f "$build_log"
  exit 1
fi
rm -f "$build_log"

# Each build adds about 1 GB to the VM's containerd disk. Prune the build cache and untagged
# images so repeated runs don't fill it. Images in use by containers are kept by crictl.
echo "==> Pruning VM build cache and untagged images"
minikube ssh -- 'sudo buildctl prune --all >/dev/null 2>&1; sudo crictl images | awk "\$2 == \"<none>\" {print \$3}" | xargs -r sudo crictl rmi >/dev/null 2>&1' || true

echo "==> Creating authorized-keys secret from $PUBKEY"
kubectl create secret generic elfie-dev-authorized-keys \
  --from-file=authorized_keys="$PUBKEY" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deploying"
kubectl apply -f "$ROOT/k8s/dev/elfie-dev.yaml"
# Same image tag on every build, so restart to pick up a freshly built image.
kubectl rollout restart deployment/elfie-dev
kubectl rollout status deployment/elfie-dev --timeout=300s

NODE_IP="$(minikube ip)"

echo "==> Writing the elfie-dev SSH alias to ~/.ssh/config"
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"
touch "$SSH_CONFIG"
# Drop any previous elfie-dev block (its IP changes when the cluster is recreated), then append a fresh one.
tmp="$(mktemp)"
awk '/^Host /{skip = ($2 == "elfie-dev")} !skip' "$SSH_CONFIG" > "$tmp"
cat >> "$tmp" <<EOF

Host elfie-dev
  HostName $NODE_IP
  Port 2222
  User vscode
  IdentityFile ${PUBKEY%.pub}
EOF
mv "$tmp" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

echo "==> Waiting for sshd on $NODE_IP:2222"
scan=""
for _ in $(seq 30); do
  scan="$(ssh-keyscan -t ed25519 -p 2222 "$NODE_IP" 2>/dev/null || true)"
  [[ -n "$scan" ]] && break
  sleep 2
done
[[ -n "$scan" ]] || { echo "sshd not reachable at $NODE_IP:2222" >&2; exit 1; }

echo "==> Trusting the pod's SSH host key (fingerprint checked against the pod)"
POD="$(kubectl get pod -l app=elfie-dev -o jsonpath='{.items[0].metadata.name}')"
pod_fp="$(kubectl exec "$POD" -- ssh-keygen -lf /home/vscode/.ssh/host_keys/ssh_host_ed25519_key.pub | awk '{print $2}')"
scan_fp="$(echo "$scan" | ssh-keygen -lf - | awk '{print $2}')"
if [[ "$pod_fp" != "$scan_fp" ]]; then
  echo "host key mismatch: pod $pod_fp, scanned $scan_fp. Not trusting it." >&2
  exit 1
fi
ssh-keygen -R "[$NODE_IP]:2222" >/dev/null 2>&1 || true
echo "$scan" >> "$HOME/.ssh/known_hosts"

echo "==> Verifying SSH login"
ssh -o BatchMode=yes elfie-dev 'echo "    logged in as $(whoami) on $(hostname)"'

if command -v code >/dev/null 2>&1; then
  echo "==> Installing the VS Code Remote-SSH extension"
  code --install-extension ms-vscode-remote.remote-ssh --force >/dev/null
  echo "==> Opening /workspaces/elfie in VS Code"
  code --remote ssh-remote+elfie-dev /workspaces/elfie
else
  echo "VS Code 'code' command not found. In VS Code run 'Shell Command: Install code command in PATH',"
  echo "then open ssh-remote+elfie-dev /workspaces/elfie or connect via Remote-SSH to host elfie-dev."
fi
echo "==> Done. Reconnect any time with: ssh elfie-dev"
