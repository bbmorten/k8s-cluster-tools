#!/bin/bash
# Generate a single self-signed cert with SANs covering both demo hostnames
# and load it as a kubernetes.io/tls Secret in both demo namespaces.
#
# Re-runnable: existing namespaces are reused; existing secrets are replaced.

set -euo pipefail

SECRET_NAME="${SECRET_NAME:-example-tls}"
NAMESPACES=("${NS1:-test-ingress-1}" "${NS2:-test-ingress-2}")
HOSTS=("test-ingress-1.example.com" "test-ingress-2.example.com")
DAYS="${DAYS:-365}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
CERT="$WORKDIR/tls.crt"
KEY="$WORKDIR/tls.key"

san_list=""
for h in "${HOSTS[@]}"; do
  san_list+="DNS:${h},"
done
san_list="${san_list%,}"

echo "Generating self-signed cert (SAN: $san_list, ${DAYS} days)..."
openssl req -x509 -nodes -days "$DAYS" -newkey rsa:2048 \
  -keyout "$KEY" \
  -out "$CERT" \
  -subj "/CN=${HOSTS[0]}/O=Self-Signed" \
  -addext "subjectAltName=$san_list" \
  >/dev/null 2>&1

echo "Cert SANs:"
openssl x509 -in "$CERT" -noout -text | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^/  /'

for ns in "${NAMESPACES[@]}"; do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "Creating namespace $ns"
    kubectl create namespace "$ns"
  fi

  echo "Applying secret $SECRET_NAME in namespace $ns"
  kubectl create secret tls "$SECRET_NAME" \
    --cert="$CERT" \
    --key="$KEY" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo "Done. Secret '$SECRET_NAME' present in: ${NAMESPACES[*]}"
