#!/usr/bin/env bash
# 07-explain-local-path.sh — the StorageClass explainer.
#
# Prints the cluster's StorageClass list and walks through:
#   - what local-path-provisioner does (rancher.io/local-path)
#   - how it differs from this lab's nfs-client SC
#   - whether you can "use NFS with local-path" — short answer: no, but you
#     can host-mount NFS into local-path's data dir if you really insist;
#     long answer in the printed text.
#
# This script does NOT mutate the cluster.

set -euo pipefail

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
hr()    { printf -- '----------------------------------------------------------------\n'; }

bold "StorageClasses currently registered:"
kubectl get storageclass
echo

bold "Provisioners detail (which controller actually creates the PV):"
kubectl get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,DEFAULT:'.metadata.annotations.storageclass\.kubernetes\.io/is-default-class',BINDMODE:.volumeBindingMode
hr

cat <<'EXPLAIN'
local-path (rancher.io/local-path) — what it actually is

  • A tiny provisioner from Rancher that creates HostPath volumes under
    /opt/local-path-provisioner/<pvc-name>/ on whichever node the Pod
    schedules to.

  • Reclaim policy is Delete by default: PVC delete → directory rm -rf.
    Reclaim Retain is supported via SC parameter overrides.

  • volumeBindingMode is WaitForFirstConsumer: the PV is not created until
    a Pod that wants the PVC is scheduled, because the directory has to
    live on whichever node the Pod ends up on.

  • Access modes: ReadWriteOnce only. The directory is on one node — there
    is no cross-node sharing.

  Pros:
    - zero infrastructure: no NFS server, no Ceph, no cloud disks
    - latency = local SSD; great for dev clusters and small stateful workloads

  Cons:
    - data is pinned to one node. If that node dies, the data dies with it
      (or, more often: the Pod simply cannot reschedule).
    - no RWX, so anything that needs >1 reader-writer is out.

EXPLAIN

bold "How nfs-client (this lab) is different"
cat <<'NFS'
  • Provisioner k8s-sigs.io/nfs-subdir-external-provisioner runs as a Pod
    in nfs-provisioner namespace. It mounts /exports/data from the NFS
    server and creates a subdirectory per PVC.

  • Access modes: ReadWriteMany works → multiple Pods on multiple nodes
    can mount the same PVC at the same time (the 10-replica nginx demo).

  • Pods can reschedule across nodes without losing data, because the data
    lives on the NFS server, not on the kubelet's host disk.

  • Reclaim policy in this lab: Delete. The provisioner removes the subdir
    when the PVC is deleted (controlled by archiveOnDelete=false in the SC).

NFS
hr

bold 'Q: Can I "use local-path with NFS" — make local-path serve NFS-backed storage?'
cat <<'COMBO'

  The honest answer is: no, not in any clean way. local-path is a HostPath
  provisioner — it always creates the volume as a directory on a node's
  local filesystem. There is no parameter you can pass to make it write to
  a remote target.

  What people sometimes do, and why it's a trap:

    • Mount NFS at /opt/local-path-provisioner on every node.

      Now local-path's "local" directory is silently a remote one. Two
      separate PVCs that get scheduled on different nodes will be writing
      under the same NFS export (different subdirs), so you do get shared
      visibility — but local-path was never designed for that. You lose
      the WaitForFirstConsumer benefit (the data is no longer node-local),
      you still don't get RWX (local-path's StorageClass advertises RWO),
      and you've added a non-obvious dependency that any new node must
      replicate before joining.

    • Use local-path's `nodePathMap` config to point at a per-node mount.

      Same trap, slightly more configurable. Still RWO from K8s' point of
      view, still confusing.

  If you want NFS, install an NFS-aware provisioner (nfs-subdir-external-
  provisioner, like this lab; the upstream csi-driver-nfs; or a vendor
  driver). They expose RWX honestly and don't lie about access modes.

  Rule of thumb:
    local-path  → fast local scratch, RWO, no HA
    nfs-client  → shared access (RWX), survives node loss, slower

COMBO
hr

cat <<'CLOSE'
Done. To take this lab apart, run:
    ./teardown-storage-nfs.sh
CLOSE
