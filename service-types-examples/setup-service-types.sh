#!/bin/bash
# Lazy-student setup for the Service-types lab.
# Applies every manifest in ./manifests/ in numeric order:
#   00 namespace -> 10 deployment -> 20 ClusterIP -> 30 NodePort
#   -> 40 LoadBalancer -> 50 ExternalName -> 60 Headless
#
# All Services share the same backend Deployment (web-backend) except
# ExternalName, which is a pure DNS CNAME and has no selector.
#
# Uses the caller's current kubectl context. Point at the cluster first:
#   bash ../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh
#   kubectl config current-context   # should be cilium-lab

set -euo pipefail

NS="svc-types-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

echo "==> Context: $(kubectl config current-context)"
echo "==> Applying manifests from ${MANIFEST_DIR}"

# Apply every YAML in order. `kubectl apply -f <dir>` would also work, but the
# loop gives clearer per-file output and matches the teardown ordering.
for f in "${MANIFEST_DIR}"/*.yaml; do
  echo "    - applying $(basename "$f")"
  kubectl apply -f "$f"
done

echo "==> Waiting for backend pods to be Ready..."
kubectl -n "${NS}" rollout status deploy/web-backend --timeout=120s

echo
echo "==> Service inventory:"
kubectl -n "${NS}" get svc -o wide

echo
echo "==> Backend pods:"
kubectl -n "${NS}" get pods -o wide -l app=web-backend

cat <<'EOF'

==> Try it out
----------------------------------------------------------------------
ClusterIP (in-cluster only):
  kubectl -n svc-types-demo run curl --rm -it --image=curlimages/curl --restart=Never -- \
    sh -c 'for i in 1 2 3 4 5 6; do curl -s http://web-clusterip/ | grep "<h1>"; done'

NodePort (any node IP, port 30090):
  for ip in 192.168.48.31 192.168.48.32 192.168.48.33 192.168.48.34; do
    curl -s http://${ip}:30090/ | grep '<h1>'
  done

LoadBalancer (MetalLB-assigned EXTERNAL-IP):
  IP=$(kubectl -n svc-types-demo get svc web-loadbalancer \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "EXTERNAL-IP: ${IP}"
  for i in 1 2 3 4 5 6; do curl -s http://${IP}/ | grep '<h1>'; done

ExternalName (DNS CNAME, no proxy):
  kubectl -n svc-types-demo run dns --rm -it --image=busybox:1.36 --restart=Never -- \
    nslookup web-external.svc-types-demo.svc.cluster.local

Headless (one A record per ready pod):
  kubectl -n svc-types-demo run dns --rm -it --image=busybox:1.36 --restart=Never -- \
    nslookup web-headless.svc-types-demo.svc.cluster.local
----------------------------------------------------------------------

If web-loadbalancer's EXTERNAL-IP stays <pending>, MetalLB is not installed.
Run ../metallb-installation/setup-metallb.sh first.
EOF
