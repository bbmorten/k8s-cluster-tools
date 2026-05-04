#!/bin/bash
# prereq-check.sh — verify the toolchain a student needs before running the lab.
#
# Checks (with min-version where it matters):
#   go              >= 1.23
#   kubebuilder     >= v4.0   (lab tested against v4.13)
#   kubectl         (any recent version, must reach the cluster)
#   docker / podman (kubebuilder envtest + image builds)
#   make            (kubebuilder's Makefile)
#
# Also confirms `kubectl` can reach a cluster and that the user can create
# CRDs (i.e. has cluster-admin or equivalent).

set -uo pipefail

ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAILED=1; }

FAILED=0

ver_ge() { # ver_ge "1.23.4" "1.23"  -> 0 (true) if first >= second
  printf '%s\n%s\n' "$2" "$1" | sort -C -V
}

echo "==> Tool versions"

# go
if command -v go >/dev/null 2>&1; then
  GO_VER="$(go version | awk '{print $3}' | sed 's/^go//')"
  if ver_ge "${GO_VER}" "1.23"; then
    ok "go ${GO_VER} (>= 1.23)"
  else
    fail "go ${GO_VER} found, need >= 1.23"
  fi
else
  fail "go not found  — install from https://go.dev/dl/"
fi

# kubebuilder
if command -v kubebuilder >/dev/null 2>&1; then
  KB_LINE="$(kubebuilder version 2>/dev/null | head -n1)"
  KB_VER="$(echo "${KB_LINE}" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed 's/^v//')"
  if [ -n "${KB_VER}" ] && ver_ge "${KB_VER}" "4.0"; then
    ok "kubebuilder v${KB_VER} (>= v4.0)"
  else
    fail "kubebuilder version: ${KB_LINE} — need v4.0+"
  fi
else
  fail "kubebuilder not found — see https://book.kubebuilder.io/quick-start.html#installation"
fi

# kubectl
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl $(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}')"
else
  fail "kubectl not found"
fi

# Container runtime — only needed for `make docker-build` / `make deploy`.
# `make run` (the lab's main path) does NOT need one. envtest pulls etcd +
# kube-apiserver binaries via setup-envtest, also no container.
# kubebuilder's Makefile reads CONTAINER_TOOL (default: docker); set it to
# nerdctl/podman if that's what the host has.
#
# IMPORTANT: keep `make docker-build` in single quotes below — bash would
# command-substitute it inside double quotes and actually run it.
if command -v docker >/dev/null 2>&1; then
  ok 'docker present'
elif command -v nerdctl >/dev/null 2>&1; then
  ok 'nerdctl present (use CONTAINER_TOOL=nerdctl with `make docker-build` / `make deploy`)'
elif command -v podman >/dev/null 2>&1; then
  ok 'podman present (use CONTAINER_TOOL=podman with `make docker-build` / `make deploy`)'
else
  warn 'no docker / nerdctl / podman found — only needed for `make docker-build` and `make deploy`, not for `make run`'
fi

# make
if command -v make >/dev/null 2>&1; then
  ok "make present"
else
  fail "make not found"
fi

echo
echo "==> Cluster reachability"

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  fail "kubectl cannot reach the cluster — check KUBECONFIG / current context"
else
  CTX="$(kubectl config current-context 2>/dev/null || echo '?')"
  ok "current-context: ${CTX}"

  # CRD create permission — the lab installs a CRD, so this must work.
  if kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io >/dev/null 2>&1; then
    ok "user can create CustomResourceDefinitions"
  else
    fail "user cannot create CRDs in this cluster — need cluster-admin or equivalent"
  fi
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "All prerequisites look good. Run ./setup-lab.sh to scaffold the operator."
  exit 0
else
  echo "One or more prerequisites failed. Fix the items above before running setup-lab.sh."
  exit 1
fi
