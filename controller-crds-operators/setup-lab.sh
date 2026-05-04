#!/bin/bash
# setup-lab.sh — fully automated path through the lab for students who just
# want to see it work end-to-end (and instructors who want to demo).
#
# What it does:
#   1. Scaffolds a fresh kubebuilder project at ${LAB_DIR}.
#   2. Drops the canonical solution files from solution/ over the scaffold.
#   3. Runs `go mod tidy && make manifests generate`.
#   4. Installs the CRD into the current kubectl context (`make install`).
#   5. Applies a sample Website CR.
#
# What it deliberately does NOT do:
#   - Start the controller. `make run` is foreground and prints the reconcile
#     log — students should run it themselves in a second terminal so they can
#     watch it. The script tells them the exact command at the end.
#
# Re-runnable: deletes ${LAB_DIR} and starts clean every time. Override
#   LAB_DIR=/some/other/path ./setup-lab.sh
# to put the scaffold elsewhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${LAB_DIR:-${SCRIPT_DIR}/website-operator}"
DOMAIN="${DOMAIN:-example.com}"
REPO="${REPO:-github.com/example/website-operator}"
OWNER="${OWNER:-Student}"

echo "==> [0/6] Pre-flight"
bash "${SCRIPT_DIR}/prereq-check.sh"

echo
echo "==> [1/6] Resetting ${LAB_DIR}"
if [ -d "${LAB_DIR}" ]; then
  echo "    Removing existing ${LAB_DIR} (re-run from clean state)"
  rm -rf "${LAB_DIR}"
fi
mkdir -p "${LAB_DIR}"

echo
echo "==> [2/6] Scaffolding kubebuilder project"
cd "${LAB_DIR}"
kubebuilder init \
  --domain "${DOMAIN}" \
  --repo "${REPO}" \
  --owner "${OWNER}"

# `--resource --controller` tells create api to scaffold both without prompting.
kubebuilder create api \
  --group web \
  --version v1 \
  --kind Website \
  --resource --controller

echo
echo "==> [3/6] Installing solution files over the scaffold"
cp "${SCRIPT_DIR}/solution/website_types.go"      "${LAB_DIR}/api/v1/website_types.go"
cp "${SCRIPT_DIR}/solution/website_controller.go" "${LAB_DIR}/internal/controller/website_controller.go"
echo "    api/v1/website_types.go              <- solution/website_types.go"
echo "    internal/controller/website_controller.go <- solution/website_controller.go"

echo
echo "==> [4/6] go mod tidy + manifests + generate"
# `go mod tidy` pulls any new transitive imports introduced by the solution
# (none right now, but kubebuilder regenerates go.sum on first build anyway).
go mod tidy
make manifests
make generate

echo
echo "==> [5/6] Installing CRD into current cluster"
echo "    kubectl context: $(kubectl config current-context)"
make install

echo
echo "==> [6/6] Applying sample Website CR"
kubectl apply -f "${SCRIPT_DIR}/solution/samples/hello-site.yaml"

cat <<EOF

------------------------------------------------------------
Setup complete.

The CRD is installed and a sample Website "hello-site" exists, but the
controller is NOT running yet — child Deployment/Service/ConfigMap will not
appear until you start it.

Open a SECOND terminal and run:

  cd ${LAB_DIR}
  make run

In your current terminal, watch the controller do its thing:

  kubectl get websites
  kubectl get deploy,svc,cm,pods -l app=hello-site
  kubectl describe website hello-site

When you're ready to see the cool demos (self-heal, validation, cascading
delete, etc.), run:

  ${SCRIPT_DIR}/demo-magic.sh

To wipe everything (CR, CRD, scaffold dir):

  ${SCRIPT_DIR}/teardown-lab.sh
------------------------------------------------------------
EOF
