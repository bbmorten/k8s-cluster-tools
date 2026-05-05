#!/bin/bash
# Lazy-student teardown for the Service-types lab.
# Reverses setup-service-types.sh:
#   60 Headless -> 50 ExternalName -> 40 LoadBalancer -> 30 NodePort
#   -> 20 ClusterIP -> 10 Deployment -> 00 Namespace
#
# Order matters less than for MetalLB (no webhook in the way), but reversing
# keeps logs tidy and matches the install order.

set -u

NS="svc-types-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

echo "==> Context: $(kubectl config current-context)"

# Walk the manifest directory in reverse numeric order so the namespace goes
# last. --ignore-not-found makes re-runs safe.
for f in $(ls -r "${MANIFEST_DIR}"/*.yaml); do
  echo "    - deleting $(basename "$f")"
  kubectl delete -f "$f" --ignore-not-found --wait=false
done

echo "==> Waiting for namespace ${NS} to terminate..."
kubectl wait --for=delete "namespace/${NS}" --timeout=120s 2>/dev/null || true

if kubectl get namespace "${NS}" >/dev/null 2>&1; then
  echo "WARNING: namespace ${NS} still present:"
  kubectl get all -n "${NS}"
else
  echo "Namespace ${NS} is gone."
fi

echo "Service-types lab teardown complete."
