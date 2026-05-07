#!/usr/bin/env bash
# 01-install-ingress-nginx.sh — install ingress-nginx and pin its LoadBalancer
# Service to a MetalLB-allocated IP.
#
# This lab needs an ingress controller to expose Keycloak at
#   http://keycloak.k8s.lab
# behind a stable IP that's reachable from both the workstation (browser +
# kubectl) and from inside the cluster (the API server doing OIDC discovery).
#
# If you already have ingress-nginx installed (e.g. from
# ../ingress-nginx-w-certificate/), this script detects that and reuses it.
# In that case you must make sure the ingress controller's EXTERNAL-IP is
# the value of INGRESS_LB_IP below.

set -euo pipefail

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
INGRESS_LB_IP="${INGRESS_LB_IP:-192.168.48.202}"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"

if kubectl get deployment -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
  echo "ingress-nginx is already installed — reusing it."
  current_ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$current_ip" ] && [ "$current_ip" != "$INGRESS_LB_IP" ]; then
    cat <<EOF
WARNING: existing ingress controller has EXTERNAL-IP ${current_ip},
         but this lab is configured to use ${INGRESS_LB_IP}.

Either:
  (a) override INGRESS_LB_IP=${current_ip} for the rest of this lab, or
  (b) re-pin the existing Service:
        kubectl annotate svc -n ingress-nginx ingress-nginx-controller \\
          metallb.universe.tf/loadBalancerIPs=${INGRESS_LB_IP} --overwrite
        kubectl delete pod -n ingress-nginx -l app.kubernetes.io/component=controller
EOF
    exit 1
  fi
else
  echo "Installing ingress-nginx ${INGRESS_NGINX_VERSION} (cloud provider manifest)..."
  kubectl apply -f "${INGRESS_MANIFEST}"
fi

# Pin the controller Service to a specific MetalLB IP so the /etc/hosts
# entries we add later survive teardown / reinstall.
echo "Pinning ingress-nginx Service to MetalLB IP ${INGRESS_LB_IP}..."
kubectl annotate svc -n ingress-nginx ingress-nginx-controller \
  metallb.universe.tf/loadBalancerIPs="${INGRESS_LB_IP}" --overwrite

# The cloud provider manifest sets type=LoadBalancer already; this is just a
# safety net if the manifest ever changes.
kubectl patch svc -n ingress-nginx ingress-nginx-controller \
  -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null

echo "Waiting for ingress-nginx controller pod to become ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

echo "Waiting for ingress-nginx Service to receive an EXTERNAL-IP..."
for _ in $(seq 1 30); do
  ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${ip}" ]; then break; fi
  sleep 2
done

if [ -z "${ip:-}" ]; then
  echo "ERROR: ingress-nginx Service has no EXTERNAL-IP after 60s. Check MetalLB."
  echo "  kubectl logs -n metallb-system -l component=controller"
  exit 1
fi

echo "ingress-nginx is up at EXTERNAL-IP ${ip}."

if [ "${ip}" != "${INGRESS_LB_IP}" ]; then
  cat <<EOF

WARNING: ingress controller got ${ip}, not ${INGRESS_LB_IP}.

This usually means another Service is already holding ${INGRESS_LB_IP}.
Check with:
  kubectl get svc -A -o wide | grep ${INGRESS_LB_IP}

Either free that IP (and re-run this script), or override INGRESS_LB_IP for
the rest of the lab.

EOF
  exit 1
fi

echo "Done. Next: 02-deploy-openldap.sh"
