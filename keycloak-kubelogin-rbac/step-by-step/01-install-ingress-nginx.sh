#!/usr/bin/env bash
# 01-install-ingress-nginx.sh — install ingress-nginx and pin its LoadBalancer
# Service to a MetalLB-allocated IP.
#
# This lab needs an ingress controller to expose Keycloak at
#   https://keycloak.k8s.lab
# behind a stable IP that's reachable from both the workstation (browser +
# kubectl) and from inside the cluster (the API server doing OIDC discovery).
# TLS is required because K8s >= 1.30 rejects http:// in --oidc-issuer-url.
#
# Coexistence with ../ingress-nginx-w-certificate/:
#   The ingress-nginx-controller Service is a singleton in the cluster, so we
#   must not fight that lab over which MetalLB IP it pins. If a controller
#   already exists with an EXTERNAL-IP, we ADOPT that IP (and skip annotating)
#   so this lab uses whatever the other lab configured. /etc/hosts and the
#   kube-apiserver hostAliases (steps 04 and 05) read INGRESS_LB_IP the same
#   way, so they pick up the adopted value automatically.
#
#   Only when ingress-nginx is being installed fresh do we pin the IP — falling
#   back to 192.168.48.202 by default. Override with INGRESS_LB_IP=... env var.

set -euo pipefail

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"

DEFAULT_LB_IP="192.168.48.202"
existing_lb_ip="$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
INGRESS_LB_IP="${INGRESS_LB_IP:-${existing_lb_ip:-$DEFAULT_LB_IP}}"

if kubectl get deployment -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
  echo "ingress-nginx is already installed — reusing it."
  if [ -n "$existing_lb_ip" ]; then
    echo "Adopting existing controller EXTERNAL-IP ${existing_lb_ip}; not re-annotating."
    INGRESS_LB_IP="$existing_lb_ip"
  else
    # Controller deployed but no EXTERNAL-IP yet (MetalLB still allocating, or
    # a stale install). Pin to our chosen IP so MetalLB has a target.
    echo "Existing controller has no EXTERNAL-IP yet; pinning to ${INGRESS_LB_IP}..."
    kubectl annotate svc -n ingress-nginx ingress-nginx-controller \
      metallb.universe.tf/loadBalancerIPs="${INGRESS_LB_IP}" --overwrite
  fi
else
  echo "Installing ingress-nginx ${INGRESS_NGINX_VERSION} (cloud provider manifest)..."
  kubectl apply -f "${INGRESS_MANIFEST}"

  # Pin the freshly-installed controller Service to a specific MetalLB IP so
  # the /etc/hosts entries we add later survive teardown / reinstall.
  echo "Pinning ingress-nginx Service to MetalLB IP ${INGRESS_LB_IP}..."
  kubectl annotate svc -n ingress-nginx ingress-nginx-controller \
    metallb.universe.tf/loadBalancerIPs="${INGRESS_LB_IP}" --overwrite

  # The cloud provider manifest sets type=LoadBalancer already; this is just a
  # safety net if the manifest ever changes.
  kubectl patch svc -n ingress-nginx ingress-nginx-controller \
    -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null
fi

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
