#!/bin/bash
# Pod Probes Lab — Teardown
# Reverses setup-pod-probes.sh by deleting the entire pod-probes-demo
# namespace. The numeric-prefix manifests remain untouched on disk.

set -u

NAMESPACE="pod-probes-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

echo "Using kubectl context: $(kubectl config current-context)"

# Delete each example in reverse order so that any Service-backing pods
# disappear before their Services. `--ignore-not-found` keeps re-runs safe.
echo "Deleting combined Deployment + Service..."
kubectl delete -f "${MANIFEST_DIR}/60-combined-deployment.yaml" --ignore-not-found

echo "Deleting startup-demo pod..."
kubectl delete -f "${MANIFEST_DIR}/50-startup-and-liveness.yaml" --ignore-not-found

echo "Deleting readiness-exec pod + Service..."
kubectl delete -f "${MANIFEST_DIR}/40-readiness-exec.yaml" --ignore-not-found

echo "Deleting tcp-probe pod..."
kubectl delete -f "${MANIFEST_DIR}/30-liveness-tcp.yaml" --ignore-not-found

echo "Deleting liveness-http pod..."
kubectl delete -f "${MANIFEST_DIR}/20-liveness-http.yaml" --ignore-not-found

echo "Deleting liveness-exec pod..."
kubectl delete -f "${MANIFEST_DIR}/10-liveness-exec.yaml" --ignore-not-found

echo "Deleting namespace ${NAMESPACE}..."
kubectl delete -f "${MANIFEST_DIR}/00-namespace.yaml" --ignore-not-found

echo "Waiting for namespace ${NAMESPACE} to terminate..."
kubectl wait --for=delete "namespace/${NAMESPACE}" --timeout=120s 2>/dev/null || true

if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "WARNING: namespace '${NAMESPACE}' still exists:"
  kubectl get all -n "${NAMESPACE}"
else
  echo "Namespace '${NAMESPACE}' is gone."
fi

echo "Pod probes lab teardown complete."
