# storage-nfs

A teaching lab demonstrating Kubernetes persistent storage on top of NFS:

1. Turn the **last** cluster node into an NFS server and the rest into NFS clients.
2. Wire up **dynamic provisioning** with [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner).
3. Show three concrete demos — RWX shared filesystem across 10 pods, a Postgres `StatefulSet` that survives a pod restart on NFS-backed storage, and a manual / static PV with no provisioner.
4. Compare the NFS `StorageClass` with Rancher's `local-path` and answer the question students always ask: *"can I use local-path with NFS?"*

The lab is shaped like [../metallb-installation/](../metallb-installation/) — pure shell + `kubectl`, no Ansible — but split into a `step-by-step/` folder for explanatory work and lazy `setup-…` / `teardown-…` wrappers that run everything in order.

## Layout

```
storage-nfs/
├── README.md                              ← you are here
├── setup-storage-nfs.sh                   ← lazy wrapper: runs all step-by-step in order
├── teardown-storage-nfs.sh                ← reverse of setup; gated REMOVE_NFS_* / WIPE_NFS_DATA flags
├── manifests/
│   ├── 10-nfs-provisioner.yaml            ← Namespace + RBAC + Deployment + StorageClass nfs-client
│   ├── 20-shared-content-namespace.yaml   ← ns nfs-demo-shared
│   ├── 21-shared-content-pvc.yaml         ← RWX PVC, 1Gi
│   ├── 22-shared-content-seeder.yaml      ← Job that writes index.html + version.txt
│   ├── 23-nginx-shared-deployment.yaml    ← 10 nginx replicas (RO mount), Service, ConfigMap
│   ├── 30-postgres-namespace.yaml         ← ns nfs-demo-postgres
│   ├── 31-postgres-statefulset.yaml       ← Postgres StatefulSet + headless Service + Secret
│   └── 40-static-pv.yaml                  ← static PV/PVC + writer Pod (templated NFS server/path)
└── step-by-step/
    ├── 00-prereq-check.sh                 ← kubectl + SSH probes
    ├── 01-install-nfs-server.sh           ← SSH last node, install nfs-kernel-server, /etc/exports
    ├── 02-install-nfs-clients.sh          ← SSH each other node, install nfs-common, smoke-mount
    ├── 03-deploy-provisioner.sh           ← kubectl apply with __NFS_SERVER__/__NFS_PATH__ subst
    ├── 04-demo-shared-content.sh          ← apply 20..23, curl through Service to prove sharing
    ├── 05-demo-postgres-stateful.sh       ← INSERT, kubectl delete pod, SELECT — data survives
    ├── 06-demo-static-pv.sh               ← apply 40-, append a line to log.txt on the share
    └── 07-explain-local-path.sh           ← prints the local-path vs nfs-client comparison
```

## Prerequisites

- A running cluster (e.g. built by [../k8s-setup-w-cilium/playbooks/install-cluster.yaml](../k8s-setup-w-cilium/playbooks/install-cluster.yaml)).
- Workstation `kubectl` pointing at it via [../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh](../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh) (`kubectl config current-context` should be `cilium-lab`).
- Passwordless SSH+sudo to all four nodes via `../k8s-setup-w-cilium/inventory/node-ssh-key`. The lab installs `nfs-kernel-server` on the last node and `nfs-common` on the others — the kubelet does the NFS mount in the host network namespace, so the package has to be on the host, not in a Pod.
- No MetalLB or Ingress dependency. Every Service in this lab is `ClusterIP` or headless.

## Defaults

Everything below is overridable via env var; see each script's header for the exact knob.

| Setting | Default | Notes |
|---|---|---|
| NFS server node | `192.168.48.34` (`st-10-04`) | Last node in [../k8s-setup-w-cilium/inventory/nodes.ini](../k8s-setup-w-cilium/inventory/nodes.ini). |
| NFS export path | `/exports/data` | Plus `/exports/data/static-vol` for the static-PV demo. |
| NFS clients | `192.168.48.31`, `.32`, `.33` | Control plane + first two workers. |
| Allowed CIDR | `192.168.48.0/24` | Goes into `/etc/exports`. |
| StorageClass name | `nfs-client` | **Not** annotated as default — coexists with `local-path`. |
| Provisioner image | `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2` | Pinned in [manifests/10-nfs-provisioner.yaml](manifests/10-nfs-provisioner.yaml). The official `registry.k8s.io` mirror only ships `v4.0.0` / `v4.0.1` / `v4.0.2`; higher version numbers exist on community forks (Quay, ECR Public) but not here. |
| Postgres image | `postgres:16-alpine` | Pinned in [manifests/31-postgres-statefulset.yaml](manifests/31-postgres-statefulset.yaml). |
| nginx image | `nginx:1.27-alpine` | Pinned in [manifests/23-nginx-shared-deployment.yaml](manifests/23-nginx-shared-deployment.yaml). |

## Usage

### Lazy path (one shot)

```shell
cd storage-nfs
./setup-storage-nfs.sh        # runs every step-by-step/ script in order
./teardown-storage-nfs.sh     # reverse, leaves the NFS server packages alone
```

### Step-by-step (recommended for teaching)

```shell
cd storage-nfs
./step-by-step/00-prereq-check.sh
./step-by-step/01-install-nfs-server.sh
./step-by-step/02-install-nfs-clients.sh
./step-by-step/03-deploy-provisioner.sh

# Pick any of the demos in any order:
./step-by-step/04-demo-shared-content.sh
./step-by-step/05-demo-postgres-stateful.sh
./step-by-step/06-demo-static-pv.sh

# Discussion / classroom prompt:
./step-by-step/07-explain-local-path.sh
```

Each `step-by-step/*.sh` is also re-run-safe — every `kubectl apply` / `apt-get install` / `/etc/exports` mutation is idempotent.

## What each demo proves

### Demo 1 — `nfs-demo-shared` (RWX, one writer, many readers)

- `shared-content-seeder` (Job) mounts the PVC RW and writes `index.html` + `version.txt` once, then exits.
- `nginx-shared` (Deployment, 10 replicas) mounts the same PVC at `/usr/share/nginx/html` with `readOnly: true`. `topologySpreadConstraints` scatter the replicas across nodes so the demo exercises NFS mount on every worker.
- The script curls the Service ten times. The `X-Pod` header rotates (proving traffic hit different replicas) while the body is byte-identical (proving they all read from the same NFS file).

To prove the volume is genuinely shared, run the optional one-off RW pod from the script's tail to flip `version: v1` → `version: v2`. Re-curl: every replica now serves v2 with no rollout. That's RWX.

### Demo 2 — `nfs-demo-postgres` (StatefulSet persistence)

- 1-replica `StatefulSet` with `volumeClaimTemplates` → PVC `data-postgres-0` bound to a freshly-provisioned NFS subdir.
- `psql` inserts a row, then we `kubectl delete pod postgres-0`.
- `StatefulSet` recreates `postgres-0`. **The same PVC is rebound to the same NFS subdir**, so the on-disk Postgres files are still there.
- We `SELECT` the row back. Persistence proven.

The point: a `StatefulSet`'s pod identity (`postgres-0`) is stable, and the PVC made from `volumeClaimTemplates` is named after that identity (`data-postgres-0`). Re-creating the pod re-binds the same PVC → same NFS subdir → same data.

> **Production caveat:** NFS for PostgreSQL is generally a bad idea. NFS file-locking and `fsync` semantics have historically caused corruption. For real Postgres at any scale use block storage (Longhorn, Rook-Ceph RBD, cloud EBS).

### Demo 3 — `nfs-demo-static` (no provisioner)

- The cluster admin pre-creates a `PersistentVolume` pointing at `192.168.48.34:/exports/data/static-vol`. The PV uses `claimRef` to pre-bind the PVC name that's allowed to consume it.
- A developer's `PersistentVolumeClaim` (matching the pre-bound name) binds without going through any dynamic provisioner.
- A `Pod` mounts the PVC and appends a line to `log.txt`.

Use case: an existing NFS appliance you don't want a provisioner to write subdirectories into. You'll size and lifecycle each PV by hand.

## StorageClass discussion: `local-path` vs `nfs-client`

Run [step-by-step/07-explain-local-path.sh](step-by-step/07-explain-local-path.sh) for a print-out, or read the short version below.

| | `local-path` (rancher.io/local-path) | `nfs-client` (this lab) |
|---|---|---|
| Backing store | Directory on a single node's local disk | Subdirectory on a remote NFS share |
| Access modes | `ReadWriteOnce` only | `ReadWriteOnce`, `ReadWriteMany` |
| Reclaim | `Delete` (rm -rf the dir) | `Delete` via `archiveOnDelete=false` |
| Volume binding mode | `WaitForFirstConsumer` (PV created on the chosen node) | `Immediate` |
| Survives node loss? | No — data lives on one node | Yes — data lives on the NFS server |
| Performance | Local SSD speed | NFS network round-trips |
| Operational cost | Zero | An NFS server (this lab uses one of the cluster nodes) |

**"Can I use local-path *with* NFS?"** The honest answer is *no*. local-path is a HostPath provisioner — it always creates the volume as a directory on a node's local filesystem. There's no parameter that makes it write to a remote target.

What people sometimes try, and why it's a trap:

- **Mount NFS at `/opt/local-path-provisioner/` on every node.** Now the "local" directory is silently remote. You lose the `WaitForFirstConsumer` benefit, you still don't get `RWX` (local-path advertises `RWO`), and you've added a non-obvious dependency that every new node must replicate before joining.
- **Use local-path's `nodePathMap` config to point at a per-node NFS mount.** Same trap, slightly more configurable.

If you want NFS, use an NFS-aware provisioner (`nfs-subdir-external-provisioner` like this lab; the upstream `csi-driver-nfs`; or a vendor driver). They expose `RWX` honestly and don't lie about access modes.

Rule of thumb:
- `local-path` → fast local scratch, `RWO`, no HA across nodes.
- `nfs-client` → shared access (`RWX`), survives node loss, slower.

## Inspecting the lab

```shell
# StorageClasses on the cluster
kubectl get sc

# Provisioner pod
kubectl -n nfs-provisioner get pods
kubectl -n nfs-provisioner logs deploy/nfs-client-provisioner

# All PVs+PVCs created by the lab
kubectl get pv,pvc -A | grep -E 'nfs-demo|nfs-pv-static'

# What's actually on the NFS server
ssh vm@192.168.48.34 'sudo ls -l /exports/data && sudo find /exports/data -maxdepth 2 -mindepth 1'
```

## Versions

Everything is pinned inline; no shared variable. Bump in lockstep:

| Component | File | Pin |
|---|---|---|
| nfs-subdir-external-provisioner | [manifests/10-nfs-provisioner.yaml](manifests/10-nfs-provisioner.yaml) | `v4.0.2` (latest tag on `registry.k8s.io`) |
| Postgres | [manifests/31-postgres-statefulset.yaml](manifests/31-postgres-statefulset.yaml) | `postgres:16-alpine` |
| nginx | [manifests/23-nginx-shared-deployment.yaml](manifests/23-nginx-shared-deployment.yaml) | `nginx:1.27-alpine` |
| busybox seeder/writer | [manifests/22-shared-content-seeder.yaml](manifests/22-shared-content-seeder.yaml), [manifests/40-static-pv.yaml](manifests/40-static-pv.yaml) | `busybox:1.36` |
| curlimages/curl probe | [step-by-step/04-demo-shared-content.sh](step-by-step/04-demo-shared-content.sh) | `curlimages/curl:8.10.1` |

## Troubleshooting

- **`MountVolume.SetUp failed for volume "..." : mount failed: exit status 32`** — the kubelet can't mount NFS. Likely `nfs-common` is missing on the node where the Pod landed. Re-run [step-by-step/02-install-nfs-clients.sh](step-by-step/02-install-nfs-clients.sh).
- **PVC stuck `Pending`** — `kubectl describe pvc <name>` typically points at a provisioner failure. Check `kubectl -n nfs-provisioner logs deploy/nfs-client-provisioner`. Common causes: NFS server unreachable from the provisioner Pod, or `/exports/data` not exported to the cluster CIDR.
- **`postgres-0` `CrashLoopBackOff` after delete** — the `PGDATA` directory on the NFS subdir wasn't owned by `postgres` (uid 70 in the alpine image). The provisioner creates subdirs as `nobody:nogroup` mode `0777`, which Postgres accepts. If you bind-mount someone else's existing data, fix ownership manually: `ssh vm@192.168.48.34 'sudo chown -R 70:70 /exports/data/nfs-demo-postgres-data-postgres-0'`.
- **`exportfs: <addr>: No 'sync' or 'async' option specified for export...`** — newer `nfs-utils` warns when the option is missing; harmless. Re-run [step-by-step/01-install-nfs-server.sh](step-by-step/01-install-nfs-server.sh) — its export line includes `sync`.
- **`kubectl wait` timeout on `pvc/...=Bound`** — the provisioner pod isn't running. `kubectl -n nfs-provisioner get pods` and check the container image was pulled.
- **`TASK [...] => FAILED! ... Permission denied (publickey)`** — the SSH key is missing or wrong; pass `SSH_KEY=/path/to/key` or set up the key listed in `00-prereq-check.sh`.
- **Lab works once, breaks on second `setup-storage-nfs.sh`** — should be impossible (everything is idempotent); if it does, please open an issue with the failed step's log. As a workaround, run `teardown-storage-nfs.sh REMOVE_NFS_SERVER=1 WIPE_NFS_DATA=1` and start fresh.
