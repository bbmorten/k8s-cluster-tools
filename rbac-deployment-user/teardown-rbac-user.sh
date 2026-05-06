#!/bin/bash
# RBAC user lab — teardown
# Reverses setup-rbac-user.sh: removes RoleBinding/Role/namespace/CSR and the
# locally generated kubeconfig file. Idempotent — safe to re-run.

set -u

USER_NAME="${USER_NAME:-dev-deploy}"
NAMESPACE="${NAMESPACE:-dev-apps}"
OUTPUT_DIR="${OUTPUT_DIR:-./kubeconfigs}"
KUBECONFIG_OUT="${OUTPUT_DIR}/${USER_NAME}.kubeconfig"

echo "==> Deleting RoleBinding 'deployment-creator-binding' in ${NAMESPACE}"
kubectl delete rolebinding deployment-creator-binding -n "${NAMESPACE}" --ignore-not-found

echo "==> Deleting Role 'deployment-creator' in ${NAMESPACE}"
kubectl delete role deployment-creator -n "${NAMESPACE}" --ignore-not-found

echo "==> Deleting namespace '${NAMESPACE}' (also wipes any Deployments the user created)"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo "==> Deleting CertificateSigningRequest '${USER_NAME}'"
kubectl delete csr "${USER_NAME}" --ignore-not-found

echo "==> Removing local kubeconfig"
rm -f "${KUBECONFIG_OUT}"
rmdir "${OUTPUT_DIR}" 2>/dev/null || true

echo "==> Verifying cleanup"
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "WARNING: namespace '${NAMESPACE}' still exists (may be Terminating)"
else
  echo "Namespace '${NAMESPACE}' is gone."
fi
if kubectl get csr "${USER_NAME}" >/dev/null 2>&1; then
  echo "WARNING: CSR '${USER_NAME}' still exists"
else
  echo "CSR '${USER_NAME}' is gone."
fi

echo "RBAC user teardown complete."
echo "Note: the issued client certificate cannot be revoked — it remains valid"
echo "until expiry, but with no Role/RoleBinding it can no longer do anything."
