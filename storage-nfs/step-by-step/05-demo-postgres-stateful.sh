#!/usr/bin/env bash
# 05-demo-postgres-stateful.sh — StatefulSet persistence demo with NFS.
#
# Walks the student through:
#   1. Apply the StatefulSet → wait for postgres-0 Ready.
#   2. Create a table, insert a row.
#   3. Delete postgres-0 → StatefulSet recreates it.
#   4. Re-query → row survived (same NFS subdir was rebound).
#
# The point: a Pod's identity in a StatefulSet is `${name}-${ordinal}`, and
# the PVC made from `volumeClaimTemplates` is named after that identity
# (`data-postgres-0`). Re-creating the Pod re-binds the same PVC → same
# NFS subdir → same data.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
NS="nfs-demo-postgres"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

step "applying namespace + Postgres StatefulSet"
kubectl apply -f "${MANIFESTS_DIR}/30-postgres-namespace.yaml"
kubectl apply -f "${MANIFESTS_DIR}/31-postgres-statefulset.yaml"

step "waiting for postgres-0 Ready (timeout 180s)"
kubectl -n "${NS}" rollout status statefulset/postgres --timeout=180s
kubectl -n "${NS}" wait --for=condition=Ready pod/postgres-0 --timeout=120s

step "showing the bound PVC + PV"
kubectl -n "${NS}" get pvc -l app=postgres
kubectl get pv -o wide | awk 'NR==1 || /nfs-demo-postgres/'

# Belt-and-suspenders against the docker-entrypoint init-restart race:
# the readinessProbe in the manifest forces a TCP probe so this should
# already pass on the first try, but a brief poll here means an old/stale
# manifest (or a different postgres image) still recovers gracefully.
step "verifying the demo DB is reachable (poll, up to 60s)"
deadline=$(( $(date +%s) + 60 ))
until kubectl -n "${NS}" exec -i postgres-0 -- \
        env PGPASSWORD=demopass psql -U demo -d demo -tAc 'SELECT 1' >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: demo DB never became reachable. Logs:"
    kubectl -n "${NS}" logs postgres-0 --tail=40
    exit 1
  fi
  sleep 2
done
echo "✓ demo DB reachable"

step "creating table + inserting a row"
kubectl -n "${NS}" exec -i postgres-0 -- \
  env PGPASSWORD=demopass psql -U demo -d demo -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS visits (
  id          serial PRIMARY KEY,
  hostname    text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO visits (hostname) VALUES ('before-restart');
SELECT id, hostname, inserted_at FROM visits ORDER BY id;
SQL

step "deleting postgres-0 to force a reschedule"
kubectl -n "${NS}" delete pod postgres-0
echo "(StatefulSet will recreate postgres-0 with the same identity and PVC)"

step "waiting for the new postgres-0 to come back Ready (timeout 180s)"
kubectl -n "${NS}" wait --for=condition=Ready pod/postgres-0 --timeout=180s

step "querying the table — the row from before the kill should still be here"
kubectl -n "${NS}" exec -i postgres-0 -- \
  env PGPASSWORD=demopass psql -U demo -d demo -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO visits (hostname) VALUES ('after-restart');
SELECT id, hostname, inserted_at FROM visits ORDER BY id;
SQL

cat <<EOF

✓ Postgres survived a Pod restart on NFS-backed storage.

  Things to discuss with students:
    - The PVC name is bound to the Pod identity:
        kubectl -n ${NS} get pvc data-postgres-0
    - The same NFS subdir is reused on reschedule:
        kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="${NS}")]}{.spec.nfs.path}{"\n"}{end}'
    - On the NFS server, look under /exports/data/${NS}-data-postgres-0/
      to see Postgres' files (PG_VERSION, base/, pg_wal/, ...) on disk.

  Caveat for production:
    NFS for Postgres is generally a bad idea (locking, fsync semantics).
    Use block storage (Longhorn, Rook-Ceph RBD, cloud EBS) for real DBs.

  Continue with 06-demo-static-pv.sh.
EOF
