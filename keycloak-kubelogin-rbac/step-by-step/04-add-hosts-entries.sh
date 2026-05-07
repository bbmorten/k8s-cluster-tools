#!/usr/bin/env bash
# 04-add-hosts-entries.sh — add keycloak.k8s.lab + ldap.k8s.lab to /etc/hosts
# on the workstation so the browser (during the kubelogin login flow) and
# kubectl can both reach Keycloak via the MetalLB-allocated ingress IP.
#
# This script does NOT touch /etc/hosts on the cluster nodes — the API server
# gets its DNS via hostAliases in the kube-apiserver static pod (added in
# step 05).
#
# Run with sudo or be prepared to type your password when sed touches /etc/hosts.

set -euo pipefail

INGRESS_LB_IP="${INGRESS_LB_IP:-192.168.48.202}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
MARKER_BEGIN="# >>> keycloak-kubelogin-rbac lab (managed) >>>"
MARKER_END="# <<< keycloak-kubelogin-rbac lab (managed) <<<"

block=$(cat <<EOF
${MARKER_BEGIN}
${INGRESS_LB_IP} keycloak.k8s.lab
${INGRESS_LB_IP} ldap.k8s.lab
${MARKER_END}
EOF
)

if grep -qF "${MARKER_BEGIN}" "${HOSTS_FILE}"; then
  echo "Lab hosts block already present in ${HOSTS_FILE} — replacing it."
  sudo sed -i "/${MARKER_BEGIN}/,/${MARKER_END}/d" "${HOSTS_FILE}"
fi

printf '%s\n' "${block}" | sudo tee -a "${HOSTS_FILE}" >/dev/null

echo
echo "Added to ${HOSTS_FILE}:"
echo "${block}"
echo

if getent hosts keycloak.k8s.lab >/dev/null 2>&1; then
  resolved=$(getent hosts keycloak.k8s.lab | awk '{print $1}')
  if [ "$resolved" = "$INGRESS_LB_IP" ]; then
    echo "Resolution check: keycloak.k8s.lab → ${resolved} ✓"
  else
    echo "WARNING: keycloak.k8s.lab resolves to ${resolved}, expected ${INGRESS_LB_IP}."
    echo "  Another /etc/hosts entry may be shadowing this one. Edit it manually."
    exit 1
  fi
else
  echo "WARNING: keycloak.k8s.lab does not resolve. nsswitch might not be checking /etc/hosts."
  exit 1
fi

# Probe the actual ingress while we're here.
if curl -fsS --max-time 5 http://keycloak.k8s.lab/realms/k8s/.well-known/openid-configuration \
     >/dev/null 2>&1; then
  echo "OIDC discovery reachable from this workstation. ✓"
else
  echo "WARNING: cannot reach http://keycloak.k8s.lab/realms/k8s/.well-known/openid-configuration"
  echo "  - Is Keycloak ready?     kubectl get pod -n identity"
  echo "  - Is ingress reachable?  curl -v http://${INGRESS_LB_IP}/"
fi

echo
echo "Done. Next: 05-enable-oidc-on-apiserver.sh"
