#!/usr/bin/env bash
# teardown-storage-nfs.sh — reverse setup-storage-nfs.sh.
#
# Order matters: we delete workloads (and their PVCs) before removing the
# StorageClass and provisioner so the provisioner gets a chance to delete
# the NFS subdirectories cleanly. Then we strip the static PV and finally
# the provisioner itself.
#
# Default behaviour leaves the NFS server alone (it's slow to reinstall and
# students often want to re-run the lab). To also rip the NFS server back
# down to a vanilla node, pass:
#
#     REMOVE_NFS_SERVER=1 ./teardown-storage-nfs.sh
#     # uninstalls nfs-kernel-server, restores /etc/exports
#
# To also wipe the data on the NFS server (the actual files under /exports
# /data), pass:
#
#     WIPE_NFS_DATA=1 ./teardown-storage-nfs.sh
#
# Both flags can be combined.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/manifests"

NFS_SERVER_HOST="${NFS_SERVER_HOST:-192.168.48.34}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/exports/data}"
NFS_CLIENT_HOSTS="${NFS_CLIENT_HOSTS:-192.168.48.31 192.168.48.32 192.168.48.33}"
SSH_USER="${SSH_USER:-vm}"
SSH_KEY="${SSH_KEY:-${SCRIPT_DIR}/../k8s-setup-w-cilium/inventory/node-ssh-key}"

REMOVE_NFS_SERVER="${REMOVE_NFS_SERVER:-0}"
REMOVE_NFS_CLIENTS="${REMOVE_NFS_CLIENTS:-0}"
WIPE_NFS_DATA="${WIPE_NFS_DATA:-0}"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

# ----- 1) Demo workloads (deleting PVCs triggers subdir cleanup) -----

step "demo: shared-content (nfs-demo-shared)"
kubectl delete -f "${MANIFESTS}/23-nginx-shared-deployment.yaml" --ignore-not-found
kubectl delete -f "${MANIFESTS}/22-shared-content-seeder.yaml"   --ignore-not-found
kubectl delete -f "${MANIFESTS}/21-shared-content-pvc.yaml"      --ignore-not-found
kubectl delete -f "${MANIFESTS}/20-shared-content-namespace.yaml" --ignore-not-found
kubectl wait --for=delete namespace/nfs-demo-shared --timeout=120s 2>/dev/null || true

step "demo: postgres (nfs-demo-postgres)"
kubectl delete -f "${MANIFESTS}/31-postgres-statefulset.yaml" --ignore-not-found
# StatefulSet PVCs are not auto-deleted; remove explicitly so the
# provisioner cleans up the NFS subdir.
kubectl -n nfs-demo-postgres delete pvc -l app=postgres --ignore-not-found 2>/dev/null || true
kubectl delete -f "${MANIFESTS}/30-postgres-namespace.yaml" --ignore-not-found
kubectl wait --for=delete namespace/nfs-demo-postgres --timeout=120s 2>/dev/null || true

step "demo: static PV (nfs-demo-static)"
# Templated manifest: substitute placeholders to match what setup applied.
NFS_SERVER="${NFS_SERVER:-${NFS_SERVER_HOST}}"
NFS_PATH="${NFS_PATH:-${NFS_EXPORT_PATH}}"
sed -e "s|__NFS_SERVER__|${NFS_SERVER}|g" \
    -e "s|__NFS_PATH__|${NFS_PATH}|g" \
    "${MANIFESTS}/40-static-pv.yaml" \
  | kubectl delete --ignore-not-found -f -
kubectl wait --for=delete namespace/nfs-demo-static --timeout=60s 2>/dev/null || true

# ----- 2) Provisioner + StorageClass -----

step "provisioner + StorageClass"
sed -e "s|__NFS_SERVER__|${NFS_SERVER}|g" \
    -e "s|__NFS_PATH__|${NFS_PATH}|g" \
    "${MANIFESTS}/10-nfs-provisioner.yaml" \
  | kubectl delete --ignore-not-found -f -
kubectl wait --for=delete namespace/nfs-provisioner --timeout=120s 2>/dev/null || true

# ----- 3) Optionally tear down NFS server / clients on the nodes -----

if [ "${REMOVE_NFS_SERVER}" = "1" ]; then
  step "removing nfs-kernel-server from ${NFS_SERVER_HOST}"
  if [ ! -f "$SSH_KEY" ]; then
    echo "WARN: SSH key $SSH_KEY missing — skipping server removal."
  else
    # Unquoted heredoc — values interpolate at the local shell layer; \$
    # for the remote.
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${NFS_SERVER_HOST}" "sudo bash -s" <<REMOTE
set -euo pipefail

# Drop the file we created in /etc/exports.d/. If a student ever migrated
# our line back into /etc/exports by hand, leave that alone — they own it.
rm -f /etc/exports.d/storage-nfs.exports
exportfs -ra 2>/dev/null || true

systemctl stop nfs-kernel-server 2>/dev/null || true
systemctl disable nfs-kernel-server 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
apt-get purge -y nfs-kernel-server || true
apt-get autoremove -y || true

if [ '${WIPE_NFS_DATA}' = '1' ]; then
  echo '[server] WIPE_NFS_DATA=1 — removing ${NFS_EXPORT_PATH}'
  rm -rf ${NFS_EXPORT_PATH}
else
  echo '[server] keeping data under ${NFS_EXPORT_PATH} (set WIPE_NFS_DATA=1 to remove)'
fi
REMOTE
  fi
fi

if [ "${REMOVE_NFS_CLIENTS}" = "1" ]; then
  step "removing nfs-common from client nodes (${NFS_CLIENT_HOSTS})"
  if [ ! -f "$SSH_KEY" ]; then
    echo "WARN: SSH key $SSH_KEY missing — skipping client removal."
  else
    for host in $NFS_CLIENT_HOSTS; do
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
          "${SSH_USER}@${host}" "sudo bash -s" <<'REMOTE' || true
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y nfs-common || true
apt-get autoremove -y || true
REMOTE
    done
  fi
fi

cat <<EOF

✓ Teardown complete.

Left behind on purpose (unless you set the override):
  - StorageClasses provided by other components (e.g. local-path)
  - nfs-kernel-server on ${NFS_SERVER_HOST}      (REMOVE_NFS_SERVER=1 to remove)
  - nfs-common on client nodes                    (REMOVE_NFS_CLIENTS=1 to remove)
  - data under ${NFS_EXPORT_PATH} on the server   (WIPE_NFS_DATA=1 to remove)
EOF
