#!/usr/bin/env bash
# 02-deploy-openldap.sh — deploy OpenLDAP and verify the seed users + groups
# loaded from the bootstrap LDIF.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

kubectl apply -f "$ROOT/manifests/00-namespace.yaml"
kubectl apply -f "$ROOT/manifests/20-openldap.yaml"

echo "Waiting for OpenLDAP to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=openldap \
  -n identity --timeout=180s

# Sanity check: list users via the admin bind.
# The bitnami image hashes plaintext userPassword on first run; expect to see
# uid: alice / bob / carol if the LDIF executed.
echo
echo "Verifying users imported (expecting alice, bob, carol):"
kubectl exec -n identity openldap-0 -- bash -c '
  ldapsearch -x -H ldap://localhost:1389 \
    -D "cn=admin,dc=example,dc=org" -w adminpassword \
    -b "ou=people,dc=example,dc=org" "(objectClass=inetOrgPerson)" uid \
    2>/dev/null | grep "^uid:"
'

echo
echo "Verifying groups (expecting k8s-admins, k8s-viewers):"
kubectl exec -n identity openldap-0 -- bash -c '
  ldapsearch -x -H ldap://localhost:1389 \
    -D "cn=admin,dc=example,dc=org" -w adminpassword \
    -b "ou=groups,dc=example,dc=org" "(objectClass=groupOfNames)" cn \
    2>/dev/null | grep "^cn:"
'

echo
echo "OpenLDAP is bootstrapped. Next: 03-deploy-keycloak.sh"
