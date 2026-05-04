#!/bin/bash
# Reverse setup-ingress-demo.sh in the order:
#   1. Ingress resources
#   2. Backends + ConfigMaps + Services in both namespaces
#   3. TLS secrets
#   4. Demo namespaces
#   5. ingress-nginx controller manifest

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"

echo "==> [1/5] Deleting Ingress resources"
kubectl delete -f "${SCRIPT_DIR}/manifests/ingress-test-ingress-1.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/ingress-test-ingress-2.yaml" --ignore-not-found

echo "==> [2/5] Deleting backends"
kubectl delete -f "${SCRIPT_DIR}/manifests/backends-test-ingress-1.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/backends-test-ingress-2.yaml" --ignore-not-found

echo "==> [3/5] Deleting TLS secrets"
kubectl delete secret example-tls -n test-ingress-1 --ignore-not-found
kubectl delete secret example-tls -n test-ingress-2 --ignore-not-found

echo "==> [4/5] Deleting demo namespaces"
kubectl delete namespace test-ingress-1 --ignore-not-found
kubectl delete namespace test-ingress-2 --ignore-not-found

echo "==> [5/5] Uninstalling ingress-nginx (${INGRESS_NGINX_VERSION})"
kubectl delete -f "${INGRESS_NGINX_MANIFEST}" --ignore-not-found

echo "    Waiting for ingress-nginx namespace to terminate..."
kubectl wait --for=delete namespace/ingress-nginx --timeout=120s 2>/dev/null || true

echo
echo "Verification:"
remaining_ns=$(kubectl get ns -o name 2>/dev/null \
  | grep -E '/(ingress-nginx|test-ingress-1|test-ingress-2)$' || true)
if [ -n "${remaining_ns}" ]; then
  echo "  WARNING: namespaces still present: ${remaining_ns}"
else
  echo "  All demo namespaces are gone."
fi

remaining_crds=$(kubectl get crds -o name 2>/dev/null | grep 'ingress' || true)
if [ -n "${remaining_crds}" ]; then
  echo "  Note: ingress-related CRDs still present (these may be cluster-wide):"
  echo "${remaining_crds}" | sed 's/^/    /'
fi

echo "Teardown complete."
