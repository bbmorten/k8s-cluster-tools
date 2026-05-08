#!/usr/bin/env bash
# 04-demo-shared-content.sh — RWX shared-volume demo.
#
# Apply order:
#   20  namespace          nfs-demo-shared
#   21  PVC                shared-content (1Gi, RWX, nfs-client)
#   22  Job                shared-content-seeder (writes index.html, version.txt)
#   23  Deployment+Svc+CM  10 nginx replicas mounting the PVC read-only
#
# Once everything is Ready, the script curls the Service a handful of
# times to show:
#   - all replicas serve the same byte-identical file from the shared PV
#   - the X-Pod response header rotates → traffic is hitting different pods
#
# Re-run-safe: every kubectl apply is idempotent.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
NS="nfs-demo-shared"

echo "▶ applying shared-content manifests"
kubectl apply -f "${MANIFESTS_DIR}/20-shared-content-namespace.yaml"
kubectl apply -f "${MANIFESTS_DIR}/21-shared-content-pvc.yaml"

echo
echo "▶ waiting for the PVC to bind (timeout 60s)"
# kubectl wait --for=jsonpath needs k8s 1.23+; cluster is 1.32, fine.
kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/shared-content --timeout=60s

echo
echo "▶ running seeder Job"
kubectl apply -f "${MANIFESTS_DIR}/22-shared-content-seeder.yaml"
kubectl -n "${NS}" wait --for=condition=complete \
  job/shared-content-seeder --timeout=120s

echo
echo "▶ rolling out 10 nginx replicas (read-only mount)"
kubectl apply -f "${MANIFESTS_DIR}/23-nginx-shared-deployment.yaml"
kubectl -n "${NS}" rollout status deploy/nginx-shared --timeout=180s

echo
echo "▶ pods (note the spread across nodes):"
kubectl -n "${NS}" get pods -o wide -l app=nginx-shared

echo
echo "▶ probing the Service 10× — every replica serves the same shared file"
SVC_IP=$(kubectl -n "${NS}" get svc nginx-shared -o jsonpath='{.spec.clusterIP}')
# Use a one-shot curl pod inside the cluster so we don't depend on the
# workstation having access to the ClusterIP.
kubectl -n "${NS}" run curlbox --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
  --command -- sh -c "
    for i in \$(seq 1 10); do
      curl -sS -D - -o /tmp/body \"http://${SVC_IP}/\" | grep -E '^X-Pod' || true
    done
    echo
    echo '----- response body (same for every replica) -----'
    cat /tmp/body
  "

cat <<EOF

✓ Shared-content demo running.

  Try it yourself:
    kubectl -n ${NS} get pvc,pv,pods,deploy,svc

  Modify the shared file to prove RWX semantics (one writer, many readers):
    kubectl -n ${NS} run editor --rm -i --restart=Never \\
      --image=busybox:1.36 \\
      --overrides='{"spec":{"containers":[{"name":"editor","image":"busybox:1.36","stdin":true,"tty":true,"command":["sh"],"volumeMounts":[{"name":"c","mountPath":"/c"}]}],"volumes":[{"name":"c","persistentVolumeClaim":{"claimName":"shared-content"}}]}}' \\
      -- sh -c 'sed -i "s|version: v1|version: v2|" /c/index.html; echo v2 > /c/version.txt; ls -l /c'

  Then re-curl: every nginx replica now serves v2.

  Continue with 05-demo-postgres-stateful.sh.
EOF
