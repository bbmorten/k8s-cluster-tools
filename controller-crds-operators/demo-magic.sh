#!/bin/bash
# demo-magic.sh — walk through the five "wow" moments from the lab guide,
# pausing between each so the instructor (or student) can read the output.
#
# Pre-conditions:
#   - setup-lab.sh has been run (CRD installed, hello-site CR exists).
#   - Controller is running in another terminal (`cd website-operator && make run`).
#
# Run with `--no-pause` to barrel through (CI-friendly).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAUSE=1
[ "${1:-}" = "--no-pause" ] && PAUSE=0

pause() {
  if [ "${PAUSE}" -eq 1 ]; then
    read -r -p "    [press Enter to continue]"
  else
    echo
  fi
}

hr() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$1"; }

if ! kubectl get website hello-site >/dev/null 2>&1; then
  echo "ERROR: 'hello-site' Website not found."
  echo "Run ./setup-lab.sh first, and start the controller with 'make run' in another terminal."
  exit 1
fi

hr "Initial state"
kubectl get websites
echo
kubectl get deploy,svc,cm,pods -l app=hello-site
pause

hr "Demo 1 — self-healing (delete the Deployment, watch it come back)"
echo "    \$ kubectl delete deploy hello-site"
kubectl delete deploy hello-site
echo "    waiting 5s..."
sleep 5
kubectl get deploy hello-site
pause

hr "Demo 2 — spec change triggers reconcile (replicas 3 -> 5)"
kubectl patch website hello-site --type=merge -p '{"spec":{"replicas":5}}'
echo "    waiting 10s for new pods..."
sleep 10
kubectl get pods -l app=hello-site
pause

hr "Demo 3 — HTML update propagates to the ConfigMap"
kubectl patch website hello-site --type=merge \
  -p '{"spec":{"html":"<h1>Updated content!</h1>"}}'
echo "    waiting 3s..."
sleep 3
echo "    ConfigMap data after patch:"
kubectl get cm hello-site -o jsonpath='{.data.index\.html}'; echo
echo "    (existing pods still serve the OLD content until restart — that's expected;"
echo "    nginx doesn't reload a mounted ConfigMap automatically)"
pause

hr "Demo 4 — validation rejects bad input"
echo "    Trying to apply solution/samples/bad-site.yaml (replicas=99, html=\"\")..."
kubectl apply -f "${SCRIPT_DIR}/solution/samples/bad-site.yaml" \
  || echo "    (rejected as expected — apiserver enforces the OpenAPI schema)"
pause

hr "Demo 5 — cascading delete via owner refs"
kubectl delete website hello-site
echo "    waiting 3s..."
sleep 3
echo "    children should all be gone:"
kubectl get deploy,svc,cm -l app=hello-site || true
pause

hr "Re-applying hello-site so you can keep poking around"
kubectl apply -f "${SCRIPT_DIR}/solution/samples/hello-site.yaml"
echo
echo "Done."
