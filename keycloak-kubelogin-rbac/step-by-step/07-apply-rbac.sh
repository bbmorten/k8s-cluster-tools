#!/usr/bin/env bash
# 07-apply-rbac.sh — apply the group-based ClusterRoleBindings.
# Always run this from the cert-based admin context, NOT the OIDC context,
# since the OIDC user does not yet have permission to create ClusterRoleBindings.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ADMIN_CTX="${ADMIN_CTX:-cilium-lab}"

if kubectl config get-contexts -o name | grep -qx "$ADMIN_CTX"; then
  kubectl config use-context "$ADMIN_CTX" >/dev/null
else
  echo "WARNING: admin context '$ADMIN_CTX' not present, using current context."
fi

kubectl apply -f "$ROOT/manifests/50-rbac.yaml"

echo
echo "RBAC bindings applied:"
kubectl get clusterrolebinding -l app.kubernetes.io/managed-by=keycloak-kubelogin-rbac
echo
echo "Done. Next: 08-test-login.sh (or just 'kubectl --context cilium-lab-oidc get pods -A' as alice)"
