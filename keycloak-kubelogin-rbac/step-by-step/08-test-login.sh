#!/usr/bin/env bash
# 08-test-login.sh — interactive smoke test of the OIDC login flow.
#
# Walks the student through the three personas:
#   alice / alicepass — should succeed for cluster-wide get pods
#   bob   / bobpass   — should succeed for get pods, fail for get secrets
#   carol / carolpass — should authenticate, then every action returns Forbidden
#
# Each persona uses its own kubelogin token cache directory so the script
# can run them back-to-back in the same shell without leaking sessions.

set -uo pipefail

OIDC_CTX="${OIDC_CTX:-cilium-lab-oidc}"

if ! kubectl config get-contexts -o name | grep -qx "$OIDC_CTX"; then
  echo "ERROR: OIDC context '$OIDC_CTX' not in kubeconfig. Run 06-configure-kubeconfig.sh first." >&2
  exit 1
fi

run_as() {
  local who="$1"; local pass="$2"; shift 2
  local cache_dir
  cache_dir=$(mktemp -d -t kubelogin-${who}-XXXXXX)

  cat <<EOF

============================================================
  Logging in as: ${who}  (LDAP password: ${pass})
============================================================
A browser will open. Sign in as ${who} / ${pass}.
Token cache for this run: ${cache_dir}
EOF

  KUBECACHEDIR="$cache_dir" kubectl --context "$OIDC_CTX" auth whoami -o yaml \
    --kubeconfig "${KUBECONFIG:-$HOME/.kube/config}" || true

  for cmd in "$@"; do
    echo
    echo "  $ kubectl --context $OIDC_CTX $cmd"
    KUBECACHEDIR="$cache_dir" kubectl --context "$OIDC_CTX" $cmd 2>&1 | head -20 || true
  done
}

run_as alice alicepass "get pods -A" "auth can-i '*' '*' --all-namespaces"
run_as bob   bobpass   "get pods -A" "get secrets -A" "auth can-i create deployments -n default"
run_as carol carolpass "get pods -A"

echo
echo "Test complete. Expected outcomes:"
echo "  alice  → cluster-admin: lists pods, can-i answers 'yes'"
echo "  bob    → view: lists pods, secrets blocked with 'Forbidden', can-i create deployments = 'no'"
echo "  carol  → authenticated but every API call: 'Forbidden'"
