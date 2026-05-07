#!/usr/bin/env bash
# setup-keycloak-rbac.sh — lazy one-shot install of the whole lab stack.
# Each phase is also runnable standalone from step-by-step/ if you want to
# debug, change something, or read what each step does.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${SCRIPT_DIR}/step-by-step"

step() {
  printf '\n\033[1;36m▶ %s\033[0m\n' "$1"
}

step "00 — prerequisite check"
"${STEPS_DIR}/00-prereq-check.sh"

step "01 — install ingress-nginx"
"${STEPS_DIR}/01-install-ingress-nginx.sh"

step "02 — deploy OpenLDAP"
"${STEPS_DIR}/02-deploy-openldap.sh"

step "03 — deploy Keycloak (+Postgres, +realm import)"
"${STEPS_DIR}/03-deploy-keycloak.sh"

step "04 — add /etc/hosts entries"
"${STEPS_DIR}/04-add-hosts-entries.sh"

step "05 — enable OIDC on the API server"
"${STEPS_DIR}/05-enable-oidc-on-apiserver.sh"

step "06 — configure kubeconfig (OIDC context)"
"${STEPS_DIR}/06-configure-kubeconfig.sh"

step "07 — apply RBAC bindings"
"${STEPS_DIR}/07-apply-rbac.sh"

cat <<'EOF'

============================================================
  SETUP COMPLETE
============================================================

Try logging in:

  kubectl --context cilium-lab-oidc get pods -A

A browser opens. Use one of:

  alice / alicepass   →  cluster-admin (member of LDAP group k8s-admins)
  bob   / bobpass     →  read-only     (member of LDAP group k8s-viewers)
  carol / carolpass   →  no access     (authenticated, no group binding)

Useful URLs (need /etc/hosts → MetalLB ingress IP, done by step 04):

  Keycloak admin:   http://keycloak.k8s.lab    (admin / admin)

To run the persona tests interactively:

  ./step-by-step/08-test-login.sh

To tear it all down:

  ./teardown-keycloak-rbac.sh

EOF
