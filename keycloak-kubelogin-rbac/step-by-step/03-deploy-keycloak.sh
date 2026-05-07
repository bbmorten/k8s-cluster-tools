#!/usr/bin/env bash
# 03-deploy-keycloak.sh — deploy Postgres + Keycloak (with realm import) and
# verify the OIDC discovery endpoint is reachable.
#
# After this step, Keycloak's admin UI is at http://keycloak.k8s.lab (admin/admin)
# but it's only reachable from a workstation that has /etc/hosts pointing
# keycloak.k8s.lab at the ingress IP. Step 04 takes care of that.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

kubectl apply -f "$ROOT/manifests/30-keycloak-db.yaml"

echo "Waiting for Keycloak Postgres to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak-db \
  -n identity --timeout=180s

kubectl apply -f "$ROOT/manifests/40-keycloak-realm-import.yaml"
kubectl apply -f "$ROOT/manifests/31-keycloak.yaml"

echo "Waiting for Keycloak to start (first boot runs the realm import — can take 2-3 minutes)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak \
  -n identity --timeout=600s

echo
echo "Probing OIDC discovery from inside the cluster (this is what the API server will do)..."
kubectl run -n identity --rm -i --restart=Never oidc-probe --image=curlimages/curl:8.10.1 -- \
  curl -fsS --max-time 5 -H "Host: keycloak.k8s.lab" \
    http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/realms/k8s/.well-known/openid-configuration \
  | head -c 200 || true
echo
echo

echo "Keycloak is up."
echo "  Realm:      k8s"
echo "  Admin UI:   http://keycloak.k8s.lab          (admin / admin)"
echo "  Issuer URL: http://keycloak.k8s.lab/realms/k8s"
echo
echo "Next: 04-add-hosts-entries.sh  (so your workstation + browser can resolve keycloak.k8s.lab)"
