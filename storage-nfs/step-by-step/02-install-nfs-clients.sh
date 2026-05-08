#!/usr/bin/env bash
# 02-install-nfs-clients.sh — install nfs-common on every cluster node that
# is NOT the NFS server, then test-mount /exports/data from the server.
#
# Why every node, even the control plane: kubelet on the host where a Pod
# with an NFS volume lands does the mount(2) itself, in the host network
# namespace. Without nfs-common on that node, the Pod fails to start with
# `mount: wrong fs type, bad option, bad superblock`.
#
# Idempotent: skips install where the package is already present.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NFS_SERVER_HOST="${NFS_SERVER_HOST:-192.168.48.34}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/exports/data}"
NFS_CLIENT_HOSTS="${NFS_CLIENT_HOSTS:-192.168.48.31 192.168.48.32 192.168.48.33}"
SSH_USER="${SSH_USER:-vm}"
SSH_KEY="${SSH_KEY:-${SCRIPT_DIR}/../../k8s-setup-w-cilium/inventory/node-ssh-key}"

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY" >&2
  exit 1
fi

for host in $NFS_CLIENT_HOSTS; do
  echo "▶ ${host}: install nfs-common, smoke-mount ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}"

  # Unquoted heredoc → ${NFS_SERVER_HOST}/${NFS_EXPORT_PATH} expand at the
  # local shell layer; \$VAR sequences expand on the remote.
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
      "${SSH_USER}@${host}" "sudo bash -s" <<REMOTE
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s nfs-common >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y nfs-common
else
  echo '[client] nfs-common already installed'
fi

# Smoke test: mount, write a marker file with the hostname, unmount.
TEST_DIR="\$(mktemp -d)"
trap 'umount "\${TEST_DIR}" 2>/dev/null || true; rmdir "\${TEST_DIR}" 2>/dev/null || true' EXIT

if mount -t nfs ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH} "\${TEST_DIR}"; then
  echo '[client] mount OK'
  marker="\${TEST_DIR}/.smoke-test-from-\$(hostname)"
  : > "\${marker}"
  rm -f "\${marker}"
  umount "\${TEST_DIR}"
  echo '[client] smoke test passed'
else
  echo '[client] mount FAILED — check NFS server export rules and network reachability' >&2
  exit 1
fi
REMOTE
done

echo
echo "✓ All NFS clients ready."
echo "  Continue with 03-deploy-provisioner.sh."
