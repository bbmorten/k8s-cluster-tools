#!/usr/bin/env bash
# setup-storage-nfs.sh — lazy one-shot install of the whole storage-nfs lab.
# Each phase is a standalone script under step-by-step/ that you can also
# run by hand if you want to read what it does or debug a single step.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS="${SCRIPT_DIR}/step-by-step"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

step "00 — prerequisite check"
"${STEPS}/00-prereq-check.sh"

step "01 — install NFS server on the last node"
"${STEPS}/01-install-nfs-server.sh"

step "02 — install NFS client + smoke-mount on every other node"
"${STEPS}/02-install-nfs-clients.sh"

step "03 — deploy nfs-subdir provisioner + StorageClass"
"${STEPS}/03-deploy-provisioner.sh"

step "04 — demo: 10 nginx replicas, RWX shared volume (read-only)"
"${STEPS}/04-demo-shared-content.sh"

step "05 — demo: PostgreSQL StatefulSet survives a Pod restart"
"${STEPS}/05-demo-postgres-stateful.sh"

step "06 — demo: static PV/PVC (no provisioner)"
"${STEPS}/06-demo-static-pv.sh"

step "07 — explainer: local-path vs nfs-client"
"${STEPS}/07-explain-local-path.sh"

cat <<'EOF'

============================================================
  SETUP COMPLETE
============================================================

What you have:

  - NFS server on the last cluster node (default 192.168.48.34)
    exporting /exports/data over the cluster CIDR

  - StorageClass `nfs-client` (NOT default) backed by
    nfs-subdir-external-provisioner v4.0.18

  - 3 demos running in their own namespaces:
      nfs-demo-shared    — 10 nginx replicas mounting one RWX volume RO
      nfs-demo-postgres  — Postgres StatefulSet on NFS-backed PVC
      nfs-demo-static    — manually-bound PV pointing at /exports/data/static-vol

Inspect:

  kubectl get sc
  kubectl get pv,pvc -A
  kubectl get pods -A -l app=nginx-shared
  kubectl get statefulset,pods -n nfs-demo-postgres

Tear it all down:

  ./teardown-storage-nfs.sh
EOF
