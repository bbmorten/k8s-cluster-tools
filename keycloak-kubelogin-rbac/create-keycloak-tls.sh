#!/usr/bin/env bash
# create-keycloak-tls.sh — generate a self-signed CA + Keycloak server cert and
# apply the server cert as a kubernetes.io/tls Secret in the identity namespace.
#
# Why TLS at all: Kubernetes >= 1.30 enforces `https://` for --oidc-issuer-url
# (the kube-apiserver rejects http with `URL scheme must be https`). So
# Keycloak must be reachable over HTTPS, and the kube-apiserver needs the CA
# that signed Keycloak's cert via --oidc-ca-file.
#
# This script produces a CA + server cert pair (rather than a single
# self-signed cert) so:
#   - the server cert (`tls.crt` / `tls.key`) is mounted into the ingress
#     for edge TLS termination
#   - the CA cert (`ca.crt`) is what step 05 SCPs to the control plane for
#     --oidc-ca-file, and what step 06 hands to kubelogin via
#     --certificate-authority
#
# The `Secret` is the only K8s object touched; everything else is local files
# under ${CERT_DIR}, which step 05/06 read from.
#
# Re-runnable: by default, existing CA + server cert are reused if present.
# Pass FORCE_REGEN=1 to regenerate (rotates the CA — every consumer must
# pick up the new cert).

set -euo pipefail

KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.k8s.lab}"
NS="${NS:-identity}"
SECRET_NAME="${SECRET_NAME:-keycloak-tls}"
DAYS="${DAYS:-3650}"
CERT_DIR="${CERT_DIR:-${HOME}/.keycloak-lab}"

mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"
CA_KEY="${CERT_DIR}/ca.key"
CA_CRT="${CERT_DIR}/ca.crt"
SRV_KEY="${CERT_DIR}/tls.key"
SRV_CRT="${CERT_DIR}/tls.crt"

if [ "${FORCE_REGEN:-0}" = "1" ] || [ ! -s "$CA_CRT" ] || [ ! -s "$SRV_CRT" ]; then
  echo "==> Generating self-signed CA at ${CA_CRT}"
  openssl genrsa -out "$CA_KEY" 2048 2>/dev/null
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$DAYS" \
    -subj "/CN=keycloak-kubelogin-rbac lab CA/O=keycloak-kubelogin-rbac" \
    -out "$CA_CRT" 2>/dev/null

  echo "==> Issuing server cert for ${KEYCLOAK_HOST} (signed by lab CA)"
  openssl genrsa -out "$SRV_KEY" 2048 2>/dev/null

  ext_conf="$(mktemp)"
  cat > "$ext_conf" <<EOF
subjectAltName = DNS:${KEYCLOAK_HOST}
extendedKeyUsage = serverAuth
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
EOF

  csr="$(mktemp)"
  openssl req -new -key "$SRV_KEY" -out "$csr" \
    -subj "/CN=${KEYCLOAK_HOST}/O=keycloak-kubelogin-rbac" 2>/dev/null
  openssl x509 -req -in "$csr" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$SRV_CRT" -days "$DAYS" -sha256 \
    -extfile "$ext_conf" 2>/dev/null
  rm -f "$csr" "$ext_conf"
else
  echo "==> Reusing existing CA + server cert in ${CERT_DIR} (set FORCE_REGEN=1 to rotate)"
fi

echo
echo "Cert details:"
openssl x509 -in "$SRV_CRT" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
  | sed 's/^/  /'

# Make sure the namespace exists; the openldap step normally creates it, but
# someone running this script first should not get a "namespace not found".
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

echo
echo "==> Applying TLS Secret ${SECRET_NAME} in namespace ${NS}"
kubectl create secret tls "$SECRET_NAME" \
  --cert="$SRV_CRT" --key="$SRV_KEY" -n "$NS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Done."
echo "  CA cert (for --oidc-ca-file / kubelogin --certificate-authority):"
echo "    ${CA_CRT}"
echo "  Server cert + key (used by the keycloak-tls Secret):"
echo "    ${SRV_CRT}"
echo "    ${SRV_KEY}"
