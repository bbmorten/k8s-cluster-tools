#!/bin/bash
# teardown-lab.sh — reverse of setup-lab.sh in dependency order:
#   1. Delete any Website CRs cluster-wide (cascades to child Deploy/Svc/CM
#      via owner refs; but only as long as the controller is running OR the
#      CRD is still there with garbage collection finalizers).
#   2. Uninstall the CRD (`make uninstall`).
#   3. Delete the scaffolded project directory.
#
# The controller process itself (started via `make run`) is the student's to
# stop with Ctrl-C. We don't try to find/kill it.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${LAB_DIR:-${SCRIPT_DIR}/website-operator}"

echo "==> [1/3] Deleting all Website CRs (cluster-wide)"
# If the CRD is gone already, this is a no-op.
if kubectl get crd websites.web.example.com >/dev/null 2>&1; then
  # --all across all namespaces. Each delete cascades to child Deploy/Svc/CM.
  kubectl delete website --all --all-namespaces --ignore-not-found
else
  echo "    (websites.web.example.com CRD not present — skipping)"
fi

echo
echo "==> [2/3] Uninstalling CRD via 'make uninstall' (if scaffold still exists)"
if [ -d "${LAB_DIR}" ] && [ -f "${LAB_DIR}/Makefile" ]; then
  ( cd "${LAB_DIR}" && make uninstall ) || \
    echo "    'make uninstall' returned non-zero — falling back to direct CRD delete"
fi

# Belt-and-braces: even if the scaffold is missing or `make uninstall`
# hiccups, the CRD itself shouldn't outlive the lab.
kubectl delete crd websites.web.example.com --ignore-not-found

echo
echo "==> [3/3] Removing scaffold directory ${LAB_DIR}"
if [ -d "${LAB_DIR}" ]; then
  rm -rf "${LAB_DIR}"
  echo "    Removed."
else
  echo "    (${LAB_DIR} already gone — skipping)"
fi

echo
echo "Verification:"
if kubectl get crd websites.web.example.com >/dev/null 2>&1; then
  echo "  WARNING: CRD websites.web.example.com still present"
else
  echo "  CRD gone."
fi
remaining=$(kubectl get websites.web.example.com --all-namespaces 2>/dev/null | tail -n +2 || true)
if [ -n "${remaining}" ]; then
  echo "  WARNING: leftover Website CRs: ${remaining}"
fi

echo "Teardown complete."
