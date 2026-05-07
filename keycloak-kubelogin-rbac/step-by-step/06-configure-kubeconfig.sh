#!/usr/bin/env bash
# 06-configure-kubeconfig.sh — add an OIDC user + context to the user's
# kubeconfig. The current admin context (cert-based) is left untouched, so
# the workstation still has full power for setup tasks.
#
# After this script runs, two contexts exist:
#   - cilium-lab        — cert-based admin (original)
#   - cilium-lab-oidc   — kubelogin-driven, group permissions only
#
# A first kubectl call against the OIDC context launches a browser, prompts
# for LDAP credentials, caches the resulting ID token in
# ~/.kube/cache/oidc-login/, and uses it as a Bearer.

set -euo pipefail

ADMIN_CTX="${ADMIN_CTX:-cilium-lab}"
OIDC_CTX="${OIDC_CTX:-cilium-lab-oidc}"
USER_NAME="${USER_NAME:-cilium-lab-oidc-user}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.k8s.lab}"
ISSUER="${ISSUER:-http://${KEYCLOAK_HOST}/realms/k8s}"
CLIENT_ID="${CLIENT_ID:-kubernetes}"
CLIENT_SECRET="${CLIENT_SECRET:-kubernetes-client-secret}"

if ! kubectl config get-contexts -o name | grep -qx "$ADMIN_CTX"; then
  echo "ERROR: admin context '$ADMIN_CTX' not in kubeconfig." >&2
  echo "       Run ../../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh first" >&2
  echo "       (or override ADMIN_CTX=...)." >&2
  exit 1
fi

# Decide whether to use the kubelogin binary or the krew plugin form.
if command -v kubelogin >/dev/null; then
  KUBELOGIN_CMD=kubelogin
  echo "Using kubelogin binary: $(command -v kubelogin)"
elif kubectl plugin list 2>/dev/null | grep -q oidc_login; then
  KUBELOGIN_CMD="kubectl"
  echo "Using kubectl plugin oidc-login"
else
  cat <<'WARN' >&2
WARNING: kubelogin not detected. Install with one of:
  sudo apt install kubelogin
  kubectl krew install oidc-login
The kubeconfig will still be written; auth fails until you install it.
WARN
  KUBELOGIN_CMD="kubectl"
fi

echo "Adding OIDC user '$USER_NAME' to kubeconfig..."
if [ "$KUBELOGIN_CMD" = "kubelogin" ]; then
  kubectl config set-credentials "$USER_NAME" \
    --exec-api-version=client.authentication.k8s.io/v1 \
    --exec-interactive-mode=IfAvailable \
    --exec-command=kubelogin \
    --exec-arg=get-token \
    --exec-arg=--oidc-issuer-url="$ISSUER" \
    --exec-arg=--oidc-client-id="$CLIENT_ID" \
    --exec-arg=--oidc-client-secret="$CLIENT_SECRET" \
    --exec-arg=--oidc-extra-scope=email \
    --exec-arg=--oidc-extra-scope=profile \
    --exec-arg=--oidc-extra-scope=groups
else
  kubectl config set-credentials "$USER_NAME" \
    --exec-api-version=client.authentication.k8s.io/v1 \
    --exec-interactive-mode=IfAvailable \
    --exec-command=kubectl \
    --exec-arg=oidc-login \
    --exec-arg=get-token \
    --exec-arg=--oidc-issuer-url="$ISSUER" \
    --exec-arg=--oidc-client-id="$CLIENT_ID" \
    --exec-arg=--oidc-client-secret="$CLIENT_SECRET" \
    --exec-arg=--oidc-extra-scope=email \
    --exec-arg=--oidc-extra-scope=profile \
    --exec-arg=--oidc-extra-scope=groups
fi

# Reuse the cluster definition from the admin context (same CA + server URL).
CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ADMIN_CTX\")].context.cluster}")
if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: could not resolve cluster name for context '$ADMIN_CTX'." >&2
  exit 1
fi

kubectl config set-context "$OIDC_CTX" \
  --cluster="$CLUSTER_NAME" \
  --user="$USER_NAME"

cat <<EOF

Kubeconfig updated.

  Admin context (cert-based, full power):
      kubectl config use-context $ADMIN_CTX

  OIDC context (logs in via Keycloak, RBAC by group):
      kubectl config use-context $OIDC_CTX

Next: 07-apply-rbac.sh   (run from the admin context — it needs ClusterRoleBinding write access)
EOF
