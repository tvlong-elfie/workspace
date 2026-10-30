#!/usr/bin/env bash
# Start sshd for VS Code Remote-SSH. Runs as the vscode user, so no root is needed on port 2222.
# Host keys and the sshd config live on the persistent ssh volume, so the host identity
# survives pod restarts and recreation.
set -euo pipefail

SSH_DIR="$HOME/.ssh"
HOST_KEY_DIR="$SSH_DIR/host_keys"
CONF="$SSH_DIR/sshd_config"

mkdir -p "$HOST_KEY_DIR"
chmod 700 "$HOST_KEY_DIR"
[[ -f "$HOST_KEY_DIR/ssh_host_ed25519_key" ]] || \
  ssh-keygen -q -t ed25519 -N "" -f "$HOST_KEY_DIR/ssh_host_ed25519_key"

cat > "$CONF" <<EOF
Port 2222
ListenAddress 0.0.0.0
HostKey $HOST_KEY_DIR/ssh_host_ed25519_key
PidFile $HOST_KEY_DIR/sshd.pid
AuthorizedKeysFile /etc/elfie-dev/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PrintMotd no
Subsystem sftp internal-sftp
# SSH sessions don't inherit the image's ENV PATH, so set the npm global bin (claude) here.
SetEnv PATH=$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
EOF

# kubeconfig for kubectl and kubectx, using the pod's service account (cluster-admin, see elfie-dev.yaml).
# It reads the token file on each use, so the projected token rotates without a rewrite.
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
mkdir -p "$HOME/.kube"
cat > "$HOME/.kube/config" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: minikube
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: $SA_DIR/ca.crt
users:
  - name: elfie-dev
    user:
      tokenFile: $SA_DIR/token
contexts:
  - name: minikube
    context:
      cluster: minikube
      user: elfie-dev
      namespace: default
current-context: minikube
EOF
chmod 600 "$HOME/.kube/config"

exec /usr/sbin/sshd -D -e -f "$CONF"
