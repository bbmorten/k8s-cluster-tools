#!/usr/bin/env bash
# 01-install-nfs-server.sh — turn the last cluster node into an NFS server.
#
# Default target is st-10-04 (192.168.48.34). It will:
#   - install nfs-kernel-server
#   - create /exports/data (and /exports/data/static-vol for the static-PV demo)
#   - export the directory to the cluster CIDR with rw,sync,no_root_squash
#     by writing /etc/exports.d/storage-nfs.exports (so we don't have to edit
#     the user's /etc/exports in place — exportfs reads everything matching
#     /etc/exports.d/*.exports)
#   - reload nfsd and verify with showmount -e localhost
#
# Idempotent: re-running just rewrites /etc/exports.d/storage-nfs.exports
# and re-runs exportfs -ra.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NFS_SERVER_HOST="${NFS_SERVER_HOST:-192.168.48.34}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/exports/data}"
NFS_ALLOWED_CIDR="${NFS_ALLOWED_CIDR:-192.168.48.0/24}"
SSH_USER="${SSH_USER:-vm}"
SSH_KEY="${SSH_KEY:-${SCRIPT_DIR}/../../k8s-setup-w-cilium/inventory/node-ssh-key}"

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY" >&2
  exit 1
fi

echo "▶ installing nfs-kernel-server on ${NFS_SERVER_HOST} (path ${NFS_EXPORT_PATH}, allowed ${NFS_ALLOWED_CIDR})"

# Remote work in a single SSH so failures abort cleanly. We use an unquoted
# heredoc and interpolate the three values at the local shell layer (same
# pattern as keycloak-kubelogin-rbac/step-by-step/05) so we don't have to
# worry about whether the remote sudoers allows env-var passthrough across
# `sudo`. The values are paths and a CIDR — no shell metacharacters — so
# inlining is safe. Any literal "$" we want the remote shell to evaluate
# is escaped as "\$".
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
    "${SSH_USER}@${NFS_SERVER_HOST}" "sudo bash -s" <<REMOTE
set -euo pipefail

# 1. Install package (idempotent; apt-get install is a no-op if up-to-date).
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s nfs-kernel-server >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y nfs-kernel-server
else
  echo "[server] nfs-kernel-server already installed"
fi

# 2. Create export root + the static-PV subdirectory used by demo 06.
mkdir -p ${NFS_EXPORT_PATH} ${NFS_EXPORT_PATH}/static-vol
chown nobody:nogroup ${NFS_EXPORT_PATH} ${NFS_EXPORT_PATH}/static-vol
chmod 0777 ${NFS_EXPORT_PATH} ${NFS_EXPORT_PATH}/static-vol

# 3. Drop our export rule into /etc/exports.d/. exportfs reads
#    /etc/exports.d/*.exports in addition to /etc/exports, so we don't
#    have to edit the user's main file.
mkdir -p /etc/exports.d
cat > /etc/exports.d/storage-nfs.exports <<'EXPORTS'
# managed by storage-nfs/step-by-step/01-install-nfs-server.sh
${NFS_EXPORT_PATH}    ${NFS_ALLOWED_CIDR}(rw,sync,no_subtree_check,no_root_squash)
EXPORTS

# 4. Refresh exports and ensure the daemon is up.
exportfs -ra
systemctl enable --now nfs-kernel-server
systemctl restart nfs-kernel-server

# 5. Verify.
echo
echo '[server] /etc/exports.d/storage-nfs.exports:'
cat /etc/exports.d/storage-nfs.exports
echo
echo '[server] showmount -e localhost:'
showmount -e localhost
REMOTE

echo
echo "✓ NFS server ready at ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}"
echo "  Subdir for static-PV demo: ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}/static-vol"
echo "  Continue with 02-install-nfs-clients.sh."
