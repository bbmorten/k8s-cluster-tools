#!/usr/bin/env bash
# 00-prereq-check.sh — verify the cluster is ready for the lab.
#
# Checks performed:
#   - kubectl is on PATH and currently points at a reachable cluster
#   - MetalLB is installed (so type=LoadBalancer can get an EXTERNAL-IP)
#   - SSH to the control plane node works (we'll edit the kube-apiserver
#     static pod manifest in step 05)
#   - kubelogin (or kubectl-oidc_login) is on PATH on the workstation
#
# This script never modifies cluster state.

set -uo pipefail

CONTROL_PLANE_HOST="${CONTROL_PLANE_HOST:-192.168.48.31}"
CONTROL_PLANE_USER="${CONTROL_PLANE_USER:-vm}"
SSH_KEY="${SSH_KEY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/../k8s-setup-w-cilium/inventory/node-ssh-key}"

# Resolve INGRESS_LB_IP: env override → existing controller's EXTERNAL-IP →
# fallback default. Adopting the existing IP keeps us out of conflict with
# ../ingress-nginx-w-certificate/, which pins the same Service to .201.
DEFAULT_LB_IP="192.168.48.202"
existing_lb_ip="$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
INGRESS_LB_IP="${INGRESS_LB_IP:-${existing_lb_ip:-$DEFAULT_LB_IP}}"

fail=0
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*"; }
err()  { printf '\033[31mFAIL:\033[0m %s\n' "$*"; fail=1; }
ok()   { printf '\033[32mOK:\033[0m  %s\n' "$*"; }

# 1. kubectl reachable
if ! command -v kubectl >/dev/null; then
  err "kubectl not on PATH"
elif ! kubectl cluster-info >/dev/null 2>&1; then
  err "kubectl cannot reach the cluster — fetch a kubeconfig first (see ../../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh)"
else
  ok "kubectl points at: $(kubectl config current-context)"
fi

# 2. MetalLB installed
if kubectl get namespace metallb-system >/dev/null 2>&1 \
   && kubectl get ipaddresspool -n metallb-system >/dev/null 2>&1; then
  ok "MetalLB is installed"
  pool=$(kubectl get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null || true)
  [ -n "$pool" ] && ok "MetalLB pool: $pool (lab will pin ingress to ${INGRESS_LB_IP})"
else
  err "MetalLB not installed — run ../../metallb-installation/setup-metallb.sh first"
fi

# 3. SSH to control plane
if [ ! -f "$SSH_KEY" ]; then
  warn "SSH key not found at $SSH_KEY (override with SSH_KEY=...)"
  err  "  → step 05 (enable-oidc-on-apiserver.sh) needs SSH access to ${CONTROL_PLANE_USER}@${CONTROL_PLANE_HOST}"
else
  if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=5 "${CONTROL_PLANE_USER}@${CONTROL_PLANE_HOST}" \
       "sudo test -f /etc/kubernetes/manifests/kube-apiserver.yaml" 2>/dev/null; then
    ok "SSH to ${CONTROL_PLANE_USER}@${CONTROL_PLANE_HOST} works and the kube-apiserver manifest is present"
  else
    err "Cannot SSH to ${CONTROL_PLANE_USER}@${CONTROL_PLANE_HOST} as root (or kube-apiserver.yaml missing)"
  fi
fi

# 4. kubelogin on workstation. Two unrelated tools share the binary name:
#    - int128/kubelogin (the OIDC one — what this lab needs)
#    - Azure kubelogin (for AKS / AAD; not OIDC-generic)
# `snap install kubelogin` often pulls the Azure variant. We check the help
# text to disambiguate, and accept either the standalone int128 binary
# OR the krew plugin (`kubectl oidc-login`).
kubelogin_ok=0
if command -v kubelogin >/dev/null; then
  # Same pipeline-free pattern as 06-configure-kubeconfig.sh — avoids
  # set -u / pipefail interactions in the calling shell.
  kubelogin_help_out="$(kubelogin --help 2>&1 || true)"
  kubelogin_help_lower="${kubelogin_help_out,,}"
  if [[ "$kubelogin_help_lower" == *"azure active directory"* ]]; then
    warn "kubelogin at $(command -v kubelogin) is Microsoft's Azure variant, not int128/kubelogin"
    warn "  → fix with:  kubectl krew install oidc-login   (or remove the snap and install int128/kubelogin)"
  else
    ok "int128/kubelogin found: $(command -v kubelogin)"
    kubelogin_ok=1
  fi
fi
if [ "$kubelogin_ok" = "0" ]; then
  if kubectl plugin list 2>/dev/null | grep -q oidc_login; then
    ok "kubectl plugin oidc-login found (krew)"
  else
    warn "int128/kubelogin not found — install with one of:"
    warn "    kubectl krew install oidc-login           # via krew (recommended)"
    warn "    go install github.com/int128/kubelogin/cmd/kubelogin@latest"
    warn "  Step 06 will write a kubeconfig that calls kubelogin; auth fails until it's installed."
  fi
fi

# 4b. openssl on workstation — needed by create-keycloak-tls.sh (step 03).
# K8s >= 1.30 requires --oidc-issuer-url to be https://, so the lab must
# generate a self-signed CA + server cert before deploying Keycloak.
if command -v openssl >/dev/null; then
  ok "openssl found: $(command -v openssl)"
else
  err "openssl not on PATH — needed by create-keycloak-tls.sh to generate the TLS cert"
fi

# 5. Hostname resolution check (informational)
if getent hosts keycloak.k8s.lab >/dev/null 2>&1; then
  resolved=$(getent hosts keycloak.k8s.lab | awk '{print $1}')
  if [ "$resolved" = "$INGRESS_LB_IP" ]; then
    ok "keycloak.k8s.lab resolves locally to ${INGRESS_LB_IP}"
  else
    warn "keycloak.k8s.lab resolves to ${resolved}, expected ${INGRESS_LB_IP}. Step 04 will offer to fix /etc/hosts."
  fi
else
  warn "keycloak.k8s.lab does not resolve on this workstation yet — step 04 will add it to /etc/hosts."
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "Prerequisites satisfied. Continue with 01-install-ingress-nginx.sh."
  exit 0
else
  echo "Prerequisite check failed. Resolve the items above before continuing."
  exit 1
fi
