#!/usr/bin/env bash
# 00-prereq-check.sh — verify the lab can run on this workstation/cluster.
#
# Checks performed (no cluster mutation):
#   - kubectl on PATH and points at a reachable cluster
#   - SSH to the NFS server node works (we install nfs-kernel-server in step 01)
#   - SSH to every NFS client node works (we install nfs-common in step 02)
#   - lab SSH key exists at the expected path

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NFS_SERVER_HOST="${NFS_SERVER_HOST:-192.168.48.34}"
NFS_CLIENT_HOSTS="${NFS_CLIENT_HOSTS:-192.168.48.31 192.168.48.32 192.168.48.33}"
SSH_USER="${SSH_USER:-vm}"
SSH_KEY="${SSH_KEY:-${SCRIPT_DIR}/../../k8s-setup-w-cilium/inventory/node-ssh-key}"

fail=0
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*"; }
err()  { printf '\033[31mFAIL:\033[0m %s\n' "$*"; fail=1; }
ok()   { printf '\033[32mOK:\033[0m   %s\n' "$*"; }

# 1. kubectl reachable
if ! command -v kubectl >/dev/null; then
  err "kubectl not on PATH"
elif ! kubectl cluster-info >/dev/null 2>&1; then
  err "kubectl cannot reach the cluster — fetch a kubeconfig first (see ../../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh)"
else
  ok "kubectl points at: $(kubectl config current-context)"
fi

# 2. SSH key present
if [ ! -f "$SSH_KEY" ]; then
  err "SSH key not found at $SSH_KEY (override with SSH_KEY=...)"
else
  ok "SSH key: $SSH_KEY"
fi

# Helper: probe SSH to a host as $SSH_USER and confirm passwordless sudo.
probe_ssh() {
  local host="$1"
  if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=5 "${SSH_USER}@${host}" \
       "sudo -n true" 2>/dev/null; then
    ok "SSH+sudo to ${SSH_USER}@${host} works"
  else
    err "Cannot SSH or run passwordless sudo on ${SSH_USER}@${host}"
  fi
}

# 3. SSH probe — NFS server
[ -f "$SSH_KEY" ] && probe_ssh "$NFS_SERVER_HOST"

# 4. SSH probe — every NFS client
if [ -f "$SSH_KEY" ]; then
  for host in $NFS_CLIENT_HOSTS; do
    probe_ssh "$host"
  done
fi

# 5. Warn (don't fail) if a StorageClass already named nfs-client exists.
# Re-running setup is fine; this is just to flag potential confusion.
if kubectl get storageclass nfs-client >/dev/null 2>&1; then
  current_provisioner=$(kubectl get storageclass nfs-client -o jsonpath='{.provisioner}')
  warn "StorageClass 'nfs-client' already exists (provisioner: ${current_provisioner})"
  warn "  → step 03 will reapply; this is OK if it's from a previous run of this lab"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "Prerequisites satisfied. Continue with 01-install-nfs-server.sh."
  exit 0
else
  echo "Prerequisite check failed. Resolve the items above before continuing."
  exit 1
fi
