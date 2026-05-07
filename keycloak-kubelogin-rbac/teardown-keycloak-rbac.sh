#!/usr/bin/env bash
# teardown-keycloak-rbac.sh — reverse everything setup-keycloak-rbac.sh did.
#
# Order matters because some pieces depend on others:
#   1. Remove RBAC bindings (so OIDC users go from authorized to "Forbidden")
#   2. Delete Keycloak Ingress + Deployment + DB + realm ConfigMap
#   3. Delete OpenLDAP StatefulSet + bootstrap LDIF
#   4. Delete the identity namespace (drops anything left behind)
#   5. Strip OIDC flags + hostAliases from kube-apiserver via SSH (with
#      timestamped backup; safe to skip if you want to leave OIDC on)
#   6. Remove the OIDC user/context from kubeconfig
#   7. Remove the lab block from /etc/hosts
#   8. Clear kubelogin's token cache so a future run doesn't try a stale token
#
# By default this leaves ingress-nginx and MetalLB alone — they may be
# shared with other labs. Pass REMOVE_INGRESS_NGINX=1 to also delete it.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTROL_PLANE_HOST="${CONTROL_PLANE_HOST:-192.168.48.31}"
CONTROL_PLANE_USER="${CONTROL_PLANE_USER:-vm}"
SSH_KEY="${SSH_KEY:-${SCRIPT_DIR}/../k8s-setup-w-cilium/inventory/node-ssh-key}"

ADMIN_CTX="${ADMIN_CTX:-cilium-lab}"
OIDC_CTX="${OIDC_CTX:-cilium-lab-oidc}"
USER_NAME="${USER_NAME:-cilium-lab-oidc-user}"

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
MARKER_BEGIN="# >>> keycloak-kubelogin-rbac lab (managed) >>>"
MARKER_END="# <<< keycloak-kubelogin-rbac lab (managed) <<<"

REMOVE_INGRESS_NGINX="${REMOVE_INGRESS_NGINX:-0}"
SKIP_APISERVER_REVERT="${SKIP_APISERVER_REVERT:-0}"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

# Make sure we use the cert-based context for cluster mutation. The OIDC user
# may already be unable to talk to the API once we strip the OIDC flags.
if kubectl config get-contexts -o name | grep -qx "$ADMIN_CTX"; then
  kubectl config use-context "$ADMIN_CTX" >/dev/null 2>&1 || true
fi

step "RBAC bindings"
kubectl delete -f "${SCRIPT_DIR}/manifests/50-rbac.yaml" --ignore-not-found

step "Keycloak (Ingress + Deployment + Service + Postgres + realm ConfigMap)"
kubectl delete -f "${SCRIPT_DIR}/manifests/31-keycloak.yaml"             --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/40-keycloak-realm-import.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/30-keycloak-db.yaml"           --ignore-not-found

step "OpenLDAP (StatefulSet + Service + LDIF ConfigMap + Secret)"
kubectl delete -f "${SCRIPT_DIR}/manifests/20-openldap.yaml" --ignore-not-found

# StatefulSet PVCs are not auto-deleted; remove explicitly.
kubectl delete pvc -n identity -l app.kubernetes.io/name=openldap    --ignore-not-found
kubectl delete pvc -n identity -l app.kubernetes.io/name=keycloak-db --ignore-not-found

step "identity namespace"
kubectl delete -f "${SCRIPT_DIR}/manifests/00-namespace.yaml" --ignore-not-found
kubectl wait --for=delete namespace/identity --timeout=120s 2>/dev/null || true

if [ "$REMOVE_INGRESS_NGINX" = "1" ]; then
  step "ingress-nginx (REMOVE_INGRESS_NGINX=1)"
  INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
  kubectl delete -f \
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml" \
    --ignore-not-found
fi

if [ "$SKIP_APISERVER_REVERT" = "1" ]; then
  step "kube-apiserver (skipped — SKIP_APISERVER_REVERT=1)"
else
  step "kube-apiserver — strip OIDC flags + hostAliases"
  if [ ! -f "$SSH_KEY" ]; then
    echo "WARNING: SSH key $SSH_KEY missing — skipping API server revert."
    echo "         Run with SKIP_APISERVER_REVERT=1 to silence this, or set SSH_KEY."
  else
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
      "${CONTROL_PLANE_USER}@${CONTROL_PLANE_HOST}" "sudo python3 -" <<'PYEOF'
import os, sys, shutil
from datetime import datetime

PATH = '/etc/kubernetes/manifests/kube-apiserver.yaml'
with open(PATH) as f:
    lines = f.read().splitlines()

backup = f'{PATH}.bak-{datetime.now().strftime("%Y%m%dT%H%M%S")}'
shutil.copy(PATH, backup)
print(f'Backup: {backup}', file=sys.stderr)

out = []
i = 0
while i < len(lines):
    line = lines[i]
    s = line.lstrip()
    # Drop OIDC flags from the command list. Match both the quoted
    # ("    - '--oidc-...'") and unquoted ("    - --oidc-...") forms.
    if line.startswith("    - '--oidc-") or line.startswith('    - --oidc-'):
        i += 1
        continue
    # Drop the entire hostAliases block (begins at "  hostAliases:").
    if line.rstrip() == '  hostAliases:':
        i += 1
        # skip child lines (any line starting with at least 2 spaces and not a
        # sibling top-level key under spec)
        while i < len(lines):
            nxt = lines[i]
            if nxt.startswith('    ') or nxt.startswith('  - '):
                i += 1
                continue
            break
        continue
    out.append(line)
    i += 1

tmp = PATH + '.tmp'
with open(tmp, 'w') as f:
    f.write('\n'.join(out) + '\n')
os.replace(tmp, PATH)
print('OIDC flags + hostAliases removed.', file=sys.stderr)
PYEOF

    echo "Waiting for kube-apiserver to come back up..."
    sleep 5
    deadline=$(( $(date +%s) + 180 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if kubectl get --raw=/readyz >/dev/null 2>&1; then
        echo "API server is reachable again."
        break
      fi
      sleep 3
    done
  fi
fi

step "kubeconfig — remove OIDC user + context"
kubectl config delete-context "$OIDC_CTX"  >/dev/null 2>&1 || true
kubectl config delete-user    "$USER_NAME" >/dev/null 2>&1 || true

step "/etc/hosts — remove lab block"
if grep -qF "${MARKER_BEGIN}" "${HOSTS_FILE}" 2>/dev/null; then
  sudo sed -i "/${MARKER_BEGIN}/,/${MARKER_END}/d" "${HOSTS_FILE}"
  echo "Removed lab entries from ${HOSTS_FILE}."
else
  echo "No lab entries found in ${HOSTS_FILE} (already clean)."
fi

step "kubelogin token cache"
rm -rf "${HOME}/.kube/cache/oidc-login" 2>/dev/null || true
echo "Cleared ~/.kube/cache/oidc-login"

cat <<'EOF'

Teardown complete.

Left behind on purpose:
  - MetalLB              (shared with other labs — see ../metallb-installation/)
  - ingress-nginx        (set REMOVE_INGRESS_NGINX=1 to delete it next time)
  - any timestamped kube-apiserver.yaml.bak-* on the control plane
EOF
