#!/usr/bin/env bash
# 06-demo-static-pv.sh — provision-free NFS via a static PV/PVC pair.
#
# This is the "I already have an NFS appliance, leave it alone" flow:
#   - admin creates the PV manually, pointing at an existing NFS subdir
#   - PV uses claimRef to pre-bind the namespace+PVC name that's allowed
#     to consume it
#   - dev's PVC matches that name and binds without going through any
#     dynamic provisioner
#
# Compare with 04 (RWX via provisioner): there a PVC alone is enough; the
# provisioner creates both the subdir and the PV. Here you wire it by hand.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
NS="nfs-demo-static"

NFS_SERVER="${NFS_SERVER:-192.168.48.34}"
NFS_PATH="${NFS_PATH:-/exports/data}"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

step "applying static PV + PVC + writer Pod"
sed -e "s|__NFS_SERVER__|${NFS_SERVER}|g" \
    -e "s|__NFS_PATH__|${NFS_PATH}|g" \
    "${MANIFESTS_DIR}/40-static-pv.yaml" \
  | kubectl apply -f -

step "waiting for the PVC to bind"
kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/nfs-pvc-static --timeout=60s

step "waiting for the writer Pod to finish"
kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/static-pv-writer --timeout=120s

step "writer Pod log"
kubectl -n "${NS}" logs pod/static-pv-writer || true

step "PV / PVC state"
kubectl -n "${NS}" get pv nfs-pv-static
kubectl -n "${NS}" get pvc nfs-pvc-static

cat <<EOF

✓ Static PV demo applied.

  The Pod appended a line to /mnt/log.txt on the NFS share at
  ${NFS_SERVER}:${NFS_PATH}/static-vol/log.txt — re-run this script and
  the file will keep growing because the PV's reclaimPolicy is Retain.

  Inspect on the NFS server:
    ssh vm@${NFS_SERVER} 'sudo cat ${NFS_PATH}/static-vol/log.txt'

  Continue with 07-explain-local-path.sh for the StorageClass explainer.
EOF
