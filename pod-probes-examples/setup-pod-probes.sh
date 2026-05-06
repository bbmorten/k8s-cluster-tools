#!/bin/bash
# Pod Probes Lab — Setup
# Applies every example manifest in numeric order into the pod-probes-demo
# namespace. Uses the caller's current kubectl context.

set -u

NAMESPACE="pod-probes-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

echo "Using kubectl context: $(kubectl config current-context)"
echo "Applying probes lab manifests from ${MANIFEST_DIR}"

# Step 1: Namespace
kubectl apply -f "${MANIFEST_DIR}/00-namespace.yaml"

# Step 2: Liveness probe — exec
# busybox creates /tmp/healthy, deletes it after 30s, sleeps. The probe runs
# `cat /tmp/healthy` every 5s. Expect kubelet restarts ~35s after the pod
# starts running and every ~50s thereafter.
kubectl apply -f "${MANIFEST_DIR}/10-liveness-exec.yaml"

# Step 3: Liveness probe — HTTP
# agnhost `liveness` serves /healthz returning 200 for the first ~10s then 500.
# Expect a restart roughly every 20-30s.
kubectl apply -f "${MANIFEST_DIR}/20-liveness-http.yaml"

# Step 4: Readiness + Liveness probes — TCP socket
# agnhost netexec listens on 8080. tcpSocket probe succeeds as long as the
# port is open. No restarts expected; pod stays Ready.
kubectl apply -f "${MANIFEST_DIR}/30-liveness-tcp.yaml"

# Step 5: Readiness probe — exec
# busybox sleeps 20s then creates /tmp/ready. The pod enters Ready only after
# the probe finds the file. Service `readiness-demo` selects this pod so you
# can watch its EndpointSlice populate when the pod becomes Ready.
kubectl apply -f "${MANIFEST_DIR}/40-readiness-exec.yaml"

# Step 6: Startup + Liveness — startup gates the aggressive liveness check
# Liveness has failureThreshold=1, which would normally kill the container
# immediately. The startup probe (failureThreshold=30, periodSeconds=5,
# i.e. up to ~150s) blocks liveness until /tmp/started exists at t=30s.
kubectl apply -f "${MANIFEST_DIR}/50-startup-and-liveness.yaml"

# Step 7: Combined — startup + liveness + readiness on a real Deployment
# 2 replicas of agnhost netexec behind a ClusterIP Service. This is the
# best-practice shape: slow-tolerant startup, lenient liveness, sensitive
# readiness for traffic gating.
kubectl apply -f "${MANIFEST_DIR}/60-combined-deployment.yaml"

echo
echo "Waiting for the combined Deployment to roll out..."
kubectl -n "${NAMESPACE}" rollout status deploy/combined --timeout=180s || true

echo
echo "Pods in ${NAMESPACE}:"
kubectl -n "${NAMESPACE}" get pods -o wide

echo
echo "Probes lab is up. Suggested next steps:"
echo "  # Watch the liveness-exec pod restart counter climb:"
echo "  kubectl -n ${NAMESPACE} get pod liveness-exec -w"
echo
echo "  # Inspect probe events (look for 'Liveness probe failed'):"
echo "  kubectl -n ${NAMESPACE} describe pod liveness-http"
echo
echo "  # Watch readiness-exec flip to Ready around t=20s:"
echo "  kubectl -n ${NAMESPACE} get pod readiness-exec -w"
echo
echo "  # Watch the EndpointSlice populate when readiness-exec becomes Ready:"
echo "  kubectl -n ${NAMESPACE} get endpointslices -l kubernetes.io/service-name=readiness-demo -w"
echo
echo "  # Trigger a readiness flip by deleting the file inside the container:"
echo "  kubectl -n ${NAMESPACE} exec readiness-exec -- rm /tmp/ready"
echo
echo "  # Confirm the startup probe gates liveness (no restarts in the first 30s):"
echo "  kubectl -n ${NAMESPACE} get pod startup-demo -w"
