#!/bin/bash
# Set up the ingress-nginx demo:
#   1. Install ingress-nginx controller (pinned, archived final release v1.15.1).
#   2. Pin its LoadBalancer Service to a MetalLB IP from first-pool.
#   3. Generate a SAN-covering self-signed cert + push to both demo namespaces.
#   4. Deploy 3 HTTP backends in test-ingress-1 and 3 HTTPS backends in test-ingress-2.
#   5. Apply the two Ingress resources.
#
# Prereqs: cluster up, MetalLB installed, kubectl pointed at the cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"

# Pin a deterministic MetalLB IP so the user's external /etc/hosts stays valid
# across teardown/reinstall cycles. Override by exporting LB_IP=... before run.
LB_IP="${LB_IP:-192.168.48.201}"

echo "==> [1/5] Installing ingress-nginx ${INGRESS_NGINX_VERSION}"
kubectl apply -f "${INGRESS_NGINX_MANIFEST}"

echo "    Waiting for controller deployment to roll out..."
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s

echo "==> [2/5] Pinning controller Service to MetalLB IP ${LB_IP}"
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  -p "{\"metadata\":{\"annotations\":{\"metallb.universe.tf/loadBalancerIPs\":\"${LB_IP}\"}}}"

echo "    Waiting for LoadBalancer IP assignment..."
for i in $(seq 1 30); do
  ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${ip}" ]; then
    echo "    LoadBalancer IP: ${ip}"
    break
  fi
  sleep 2
done
if [ -z "${ip:-}" ]; then
  echo "WARNING: controller Service has no LB IP yet; check MetalLB."
fi

echo "==> [3/5] Generating SAN cert + pushing TLS secret to both namespaces"
bash "${SCRIPT_DIR}/create-tls-secret.sh"

echo "==> [4/5] Applying backend Deployments + Services"
kubectl apply -f "${SCRIPT_DIR}/manifests/backends-test-ingress-1.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/backends-test-ingress-2.yaml"

echo "    Waiting for backend pods to be ready..."
kubectl -n test-ingress-1 wait --for=condition=available --timeout=120s \
  deploy/web-a deploy/web-b deploy/web-c
kubectl -n test-ingress-2 wait --for=condition=available --timeout=120s \
  deploy/web-a deploy/web-b deploy/web-c

echo "==> [5/5] Applying Ingress resources"
kubectl apply -f "${SCRIPT_DIR}/manifests/ingress-test-ingress-1.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/ingress-test-ingress-2.yaml"

cat <<EOF

Done.

Add this to /etc/hosts on the client machine that will reach the demo:
  ${LB_IP}  test-ingress-1.example.com test-ingress-2.example.com

Then probe each path (cert is self-signed, hence -k):

  for h in test-ingress-1 test-ingress-2; do
    for p in a b c; do
      echo "--- \$h.example.com/\$p"
      curl -sk "https://\$h.example.com/\$p"
    done
  done

Expected: each request returns identifying text including the pod name,
namespace, and letter so you can confirm path-routing and namespace separation.
EOF
