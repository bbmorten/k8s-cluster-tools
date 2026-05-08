#!/usr/bin/env bash
# 03-deploy-provisioner.sh — install the nfs-subdir-external-provisioner
# and the `nfs-client` StorageClass.
#
# The provisioner watches PVCs that ask for storageClassName=nfs-client,
# creates a subdirectory on the NFS export, and binds a freshly-minted PV
# to the claim. Subdirs follow the pattern ${.PVC.namespace}-${.PVC.name}
# (set in manifests/10-nfs-provisioner.yaml's StorageClass).
#
# Idempotent: kubectl apply replays cleanly. Re-run after editing the
# manifest to roll the provisioner Deployment.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"

NFS_SERVER="${NFS_SERVER:-192.168.48.34}"
NFS_PATH="${NFS_PATH:-/exports/data}"

echo "▶ applying nfs-subdir provisioner — server ${NFS_SERVER}, path ${NFS_PATH}"

# Substitute __NFS_SERVER__ / __NFS_PATH__ in-flight so the on-disk YAML
# stays generic and reviewable. `|` is the sed delimiter so paths with `/`
# don't need escaping.
sed -e "s|__NFS_SERVER__|${NFS_SERVER}|g" \
    -e "s|__NFS_PATH__|${NFS_PATH}|g" \
    "${MANIFESTS_DIR}/10-nfs-provisioner.yaml" \
  | kubectl apply -f -

echo
echo "▶ waiting for provisioner pod to become Ready (timeout 120s)"
kubectl -n nfs-provisioner rollout status deploy/nfs-client-provisioner --timeout=120s

echo
echo "▶ StorageClasses present on this cluster:"
kubectl get storageclass

cat <<EOF

✓ Provisioner ready. Test with:

    kubectl apply -f - <<YAML
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: smoke
      namespace: default
    spec:
      accessModes: [ReadWriteMany]
      storageClassName: nfs-client
      resources: { requests: { storage: 1Gi } }
    YAML
    kubectl get pvc smoke    # should show Bound within seconds
    kubectl delete pvc smoke

  Continue with 04-demo-shared-content.sh.
EOF
