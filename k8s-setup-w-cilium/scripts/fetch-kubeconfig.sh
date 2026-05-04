#!/usr/bin/env bash
#
# Fetch /etc/kubernetes/admin.conf from the control plane, rename the
# cluster/user/context to avoid collisions with other kubeconfigs, and merge
# into ~/.kube/config.
#
# Usage:
#   bash scripts/fetch-kubeconfig.sh                      # merge into ~/.kube/config
#   bash scripts/fetch-kubeconfig.sh --standalone PATH    # write to PATH, no merge
#
# Env overrides:
#   CP_IP       control-plane IP     (default: 192.168.48.31)
#   SSH_USER    ssh user on nodes    (default: vm)
#   SSH_KEY     ssh private key      (default: inventory/node-ssh-key)
#   CTX_NAME    context/cluster name (default: cilium-lab)

set -euo pipefail

CP_IP="${CP_IP:-192.168.48.31}"
SSH_USER="${SSH_USER:-vm}"
SSH_KEY="${SSH_KEY:-inventory/node-ssh-key}"
CTX_NAME="${CTX_NAME:-cilium-lab}"
USER_NAME="${CTX_NAME}-admin"

STANDALONE=""
if [[ "${1:-}" == "--standalone" ]]; then
  STANDALONE="${2:?--standalone requires a destination path}"
fi

# -----------------------------------------------------------------------------
# Logging — tee all stdout/stderr to logs/fetch-kubeconfig-<timestamp>.log
# -----------------------------------------------------------------------------
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${PROJECT_DIR}/logs"
mkdir -p "$LOG_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/fetch-kubeconfig-${ts}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==================================================================="
echo "fetch-kubeconfig.sh start: $(date -Iseconds)"
echo "  host:       $(hostname)"
echo "  user:       $(whoami)"
echo "  cwd:        $(pwd)"
echo "  CP_IP:      $CP_IP"
echo "  SSH_USER:   $SSH_USER"
echo "  SSH_KEY:    $SSH_KEY"
echo "  CTX_NAME:   $CTX_NAME"
echo "  standalone: ${STANDALONE:-<none, merging into ~/.kube/config>}"
echo "  log:        $LOG_FILE"
echo "==================================================================="

trap 'rc=$?; echo "==================================================================="; echo "fetch-kubeconfig.sh end: $(date -Iseconds)  exit=$rc"; echo "==================================================================="' EXIT

# Run the rest with xtrace so every command lands in the log
set -x

if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: ssh key not found at $SSH_KEY (run from repo root, or set SSH_KEY)" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rc=$?; rm -f "$TMP" "$TMP.bak"; set +x; echo "==================================================================="; echo "fetch-kubeconfig.sh end: $(date -Iseconds)  exit=$rc"; echo "==================================================================="' EXIT

echo ">> Copying admin.conf off ${CP_IP}"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${CP_IP}" \
  'sudo cp /etc/kubernetes/admin.conf /home/'"${SSH_USER}"'/admin.conf && sudo chown '"${SSH_USER}:${SSH_USER}"' /home/'"${SSH_USER}"'/admin.conf'
scp -i "$SSH_KEY" "${SSH_USER}@${CP_IP}:admin.conf" "$TMP" >/dev/null
ssh -i "$SSH_KEY" "${SSH_USER}@${CP_IP}" "rm -f /home/${SSH_USER}/admin.conf"

echo ">> Rewriting names (cluster/user/context -> ${CTX_NAME}) and server URL"
kubectl --kubeconfig "$TMP" config rename-context kubernetes-admin@kubernetes "$CTX_NAME" >/dev/null
sed -i.bak \
  -e "s/name: kubernetes\$/name: ${CTX_NAME}/" \
  -e "s/cluster: kubernetes\$/cluster: ${CTX_NAME}/" \
  -e "s/name: kubernetes-admin\$/name: ${USER_NAME}/" \
  -e "s/user: kubernetes-admin\$/user: ${USER_NAME}/" \
  -e "s#server: https://[^:]*:6443#server: https://${CP_IP}:6443#" \
  "$TMP"

if [[ -n "$STANDALONE" ]]; then
  mkdir -p "$(dirname "$STANDALONE")"
  install -m 0600 "$TMP" "$STANDALONE"
  echo ">> Wrote standalone kubeconfig: $STANDALONE"
  echo "   export KUBECONFIG=$STANDALONE"
  echo "   kubectl get nodes"
  exit 0
fi

echo ">> Dropping stale entries from ~/.kube/config"
for x in \
  "config delete-context ${CTX_NAME}" \
  "config delete-cluster ${CTX_NAME}" \
  "config delete-cluster kubernetes" \
  "config delete-user ${USER_NAME}" \
  "config delete-user kubernetes-admin"
do
  kubectl $x >/dev/null 2>&1 || true
done

echo ">> Merging into ~/.kube/config"
mkdir -p "$HOME/.kube"
touch "$HOME/.kube/config"
NEW="$HOME/.kube/config.new.$$"
KUBECONFIG="$HOME/.kube/config:$TMP" kubectl config view --flatten > "$NEW"
mv "$NEW" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

kubectl config use-context "$CTX_NAME" >/dev/null
echo ">> Context set to: $CTX_NAME"
kubectl get nodes -o wide
