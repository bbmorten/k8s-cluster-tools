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
# K8s >= 1.30 requires https:// here. Must match --oidc-issuer-url and
# KC_HOSTNAME byte-for-byte (the API server compares the JWT iss claim).
ISSUER="${ISSUER:-https://${KEYCLOAK_HOST}/realms/k8s}"
CLIENT_ID="${CLIENT_ID:-kubernetes}"
CLIENT_SECRET="${CLIENT_SECRET:-kubernetes-client-secret}"

# CA cert that signed Keycloak's server cert. kubelogin uses this to verify
# the issuer URL during OIDC discovery; without it (or --insecure-skip-tls-verify)
# kubelogin rejects the self-signed cert.
CERT_DIR="${CERT_DIR:-${HOME}/.keycloak-lab}"
LAB_CA_CRT="${LAB_CA_CRT:-${CERT_DIR}/ca.crt}"
if [ ! -s "$LAB_CA_CRT" ]; then
  echo "ERROR: lab CA cert not found at $LAB_CA_CRT" >&2
  echo "       Run 03-deploy-keycloak.sh first (or bash ../create-keycloak-tls.sh)." >&2
  exit 1
fi

if ! kubectl config get-contexts -o name | grep -qx "$ADMIN_CTX"; then
  echo "ERROR: admin context '$ADMIN_CTX' not in kubeconfig." >&2
  echo "       Run ../../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh first" >&2
  echo "       (or override ADMIN_CTX=...)." >&2
  exit 1
fi

# Decide whether to use the standalone kubelogin binary or the krew plugin form.
#
# Disambiguation: there are two unrelated tools named `kubelogin`:
#   - int128/kubelogin (the OIDC one — what this lab needs)
#   - Azure's kubelogin (for AKS / AAD; help text says "azure active directory")
# If `kubelogin` resolves to the Azure variant, fall back to the krew
# plugin (`kubectl oidc-login`), which is always int128's tool.
KUBELOGIN_BIN_OK=0
if command -v kubelogin >/dev/null; then
  # Capture without piping, then string-match. Avoids set -u / pipefail
  # interactions where a startup-file error in the subshell would kill the
  # pipe before kubelogin ran and make the disambiguation false-negative.
  kubelogin_help_out="$(kubelogin --help 2>&1 || true)"
  kubelogin_help_lower="${kubelogin_help_out,,}"
  if [[ "$kubelogin_help_lower" == *"azure active directory"* ]]; then
    echo "Detected Azure kubelogin at $(command -v kubelogin) — wrong tool, ignoring."
  else
    KUBELOGIN_BIN_OK=1
  fi
fi

if [ "$KUBELOGIN_BIN_OK" = "1" ]; then
  KUBELOGIN_CMD=kubelogin
  echo "Using int128 kubelogin binary: $(command -v kubelogin)"
elif kubectl plugin list 2>/dev/null | grep -q oidc_login; then
  KUBELOGIN_CMD="kubectl"
  echo "Using kubectl plugin oidc-login (krew)"
else
  cat <<'WARN' >&2
WARNING: int128/kubelogin not detected. Install with one of:
  kubectl krew install oidc-login                        # via krew (recommended)
  go install github.com/int128/kubelogin/cmd/kubelogin@latest
NOTE: 'snap install kubelogin' often pulls Microsoft's Azure kubelogin —
that is a different tool and will not work for OIDC against Keycloak.
The kubeconfig will still be written; auth fails until int128/kubelogin
is on PATH or installed as the krew plugin.
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
    --exec-arg=--certificate-authority="$LAB_CA_CRT" \
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
    --exec-arg=--certificate-authority="$LAB_CA_CRT" \
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
