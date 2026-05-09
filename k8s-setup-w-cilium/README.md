# k8s-setup-w-cilium

Self-contained setup for a 4-node Kubernetes cluster (1 control plane + 3 workers) on Ubuntu 24.04 nodes, with **Cilium** as the CNI.

All cluster create/delete/maintenance operations are driven from `inventory/nodes.ini`. Everything needed lives inside this folder — no paths reach outside it.

This folder assumes the 4 nodes already exist and are reachable over SSH. `playbooks/install-cluster.yaml` installs the `cilium` CLI on the control plane and runs `cilium install` to bring up the CNI.

## Layout

```
k8s-setup-w-cilium/
├── ansible.cfg                 # points ansible at inventory/nodes.ini
├── run.sh                      # wrapper: ansible-playbook -b -K <file> [--check|--syntax-check|--debug=true]
├── cloud-init.yaml             # reference cloud-init used when provisioning nodes
├── inventory/
│   ├── nodes.ini               # single source of truth for hosts
│   ├── node-ssh-key            # 0600
│   └── node-ssh-key.pub
├── playbooks/
│   ├── install-cluster.yaml    # full cluster install (containerd + kubeadm + Cilium)
│   ├── delete-cluster.yaml     # kubeadm reset + package/config purge on all nodes
│   ├── apt-update-upgrade.yaml # apt update && full-upgrade on all nodes
│   ├── refresh-apt-keys.yaml   # refresh rotated third-party apt signing keys
│   └── reboot-hosts.yaml       # rolling reboot
├── scripts/
│   ├── bootstrap-nodes.sh      # one-shot prereq setup: sudoers + authorized_keys, install ansible-core/-lint
│   └── fetch-kubeconfig.sh     # copy admin.conf off control plane, merge into ~/.kube/config
└── tests/
    └── nginx-4-instances.yaml  # 4-replica nginx smoke test (shows pod name/IP/node per request)
```

## Prerequisites

- 4 Ubuntu 24.04 hosts reachable at the IPs listed in [inventory/nodes.ini](inventory/nodes.ini).
- Ansible user `vm` exists on each host with passwordless sudo.
- The public key `inventory/node-ssh-key.pub` is in `~vm/.ssh/authorized_keys` on every host.
- Local Ansible + SSH client on the workstation running `run.sh`.

Adjust IPs in [inventory/nodes.ini](inventory/nodes.ini) to match your environment before running anything.

### One-shot bootstrap

[scripts/bootstrap-nodes.sh](scripts/bootstrap-nodes.sh) brings hosts that already have a `vm` user up to the prerequisites above. It can be run from a separate workstation **or** from the first node in the inventory (any target IP that matches a local interface is handled via local `sudo` instead of SSH).

```shell
cd k8s-setup-w-cilium

# First run in the lab — vm has password but no NOPASSWD sudo yet:
SUDO_PASS='Password1!' bash scripts/bootstrap-nodes.sh

# Re-runs after the first — sudoers entry is now in place, no password needed:
bash scripts/bootstrap-nodes.sh

# First-time, when vm is initially reachable via a different SSH key:
BOOTSTRAP_KEY=~/.ssh/id_ed25519 SUDO_PASS='Password1!' bash scripts/bootstrap-nodes.sh
```

Phases:

1. **Install workstation tooling** — `ansible-core` + `ansible-lint` via `apt-get` (skipped if both already on `$PATH`).
2. **Bootstrap each node** — write `/etc/sudoers.d/90-vm` (`NOPASSWD`) and append `inventory/node-ssh-key.pub` to `~vm/.ssh/authorized_keys`. All steps idempotent.
3. **Verify** — `sudo -n whoami` must return `root` for every node (via SSH, or via local sudo for the loopback target).
4. **`ansible -m ping`** — confirms every node in `k8s_cluster` answers.

Auth notes:

- **SSH:** `vm` must already be reachable — either via `BOOTSTRAP_KEY`, an agent-loaded key, or with `inventory/node-ssh-key` already authorized.
- **sudo:** if `vm` doesn't have NOPASSWD sudo yet, set `SUDO_PASS` — the script feeds it to `sudo -S` so the very first run can install `/etc/sudoers.d/90-vm` itself. After Phase 2 completes, the sudoers entry is in place and re-runs work without `SUDO_PASS` (the verify phase enforces this — `sudo -n whoami` must return `root`).
- **Lab default:** `vm`'s password is `Password1!`, so `SUDO_PASS='Password1!' bash scripts/bootstrap-nodes.sh` for the initial run.

Env overrides: `SSH_USER`, `BOOTSTRAP_KEY`, `PUBKEY_FILE`, `PRIVKEY_FILE`, `INVENTORY`, `SUDO_PASS`. Output is teed to `logs/bootstrap-nodes-<timestamp>.log` (the password itself is never written to the log — it only crosses stdin).

## Versions

- Ubuntu 24.04 LTS on each node
- Kubernetes **1.35.4** (repo `pkgs.k8s.io/core:/stable:/v1.35`)
- Cilium **1.19.3** (installed via cilium CLI **v0.19.2**)
- containerd from Ubuntu's `universe` apt repository (the install play enables `universe` if it's missing)
- crictl latest release from `kubernetes-sigs/cri-tools` (with `v1.35.0` as a fallback)

To bump versions, edit [playbooks/install-cluster.yaml](playbooks/install-cluster.yaml): `kubernetes_version`, `cilium_version`, `cilium_cli_version`, and the two `v1.35` strings in the APT repo setup.

## Bring up a fresh cluster

Run everything from inside this folder.

```shell
# 1. Update/upgrade all nodes (safe to re-run anytime)
bash run.sh playbooks/apt-update-upgrade.yaml

# 2. Install the cluster
bash run.sh playbooks/install-cluster.yaml
```

Verify (SSH into the control plane):

```shell
ssh -i inventory/node-ssh-key vm@<control-plane-ip>
kubectl get nodes -w
kubectl get pods -n kube-system
```

## kubectl from your workstation

`kubeadm init` writes `/etc/kubernetes/admin.conf` on the control plane. Copy it to your workstation and point `kubectl` at it.

Use [scripts/fetch-kubeconfig.sh](scripts/fetch-kubeconfig.sh). Run it from the repo root (the script expects `inventory/node-ssh-key` to exist relative to `$PWD`).

```shell
# Merge into ~/.kube/config (default)
bash scripts/fetch-kubeconfig.sh

# Or write a standalone kubeconfig, no merge
bash scripts/fetch-kubeconfig.sh --standalone ~/.kube/cilium-lab.conf
export KUBECONFIG=~/.kube/cilium-lab.conf
kubectl get nodes
```

Overrides via env vars: `CP_IP`, `SSH_USER`, `SSH_KEY`, `CTX_NAME`.

What it does:

1. `scp`s `/etc/kubernetes/admin.conf` off the control plane (via a sudo-copy on the node since the file is `0600 root:root`).
2. Renames the cluster/user/context from kubeadm's defaults (`kubernetes`, `kubernetes-admin`, `kubernetes-admin@kubernetes`) to `cilium-lab`, `cilium-lab-admin`, `cilium-lab`. This is required — if you merge two kubeadm kubeconfigs without renaming, `kubectl config view --flatten` keeps the **first** cluster entry (old CA) against the new server URL, which produces `x509: certificate signed by unknown authority` errors.
3. Rewrites the server URL to `https://$CP_IP:6443`.
4. Deletes any stale `cilium-lab`/`kubernetes` entries already in `~/.kube/config`, then merges.
5. Sets the current context to `cilium-lab` and runs `kubectl get nodes -o wide`.

Notes:

- The API server listens on `6443`. Make sure your workstation can reach `<control-plane-ip>:6443` (same L2, or a route/tunnel).
- `admin.conf` is a **cluster-admin credential** — treat it like a root password. For day-to-day use, create a scoped ServiceAccount + kubeconfig instead.
- Safely re-runnable — rerun after a cluster rebuild to pick up the new CA.

## Smoke-test the cluster with 4 nginx pods

[tests/nginx-4-instances.yaml](tests/nginx-4-instances.yaml) deploys 4 nginx replicas (one per node via a `topologySpreadConstraints` hint) behind a NodePort service on port `30080`. Each pod uses the Downward API to render an index page showing its **pod name**, **pod IP**, **node**, and **container hostname** — so repeated requests to the service reveal how traffic is load-balanced across replicas.

```shell
kubectl apply -f tests/nginx-4-instances.yaml
kubectl -n nginx-demo get pods -o wide          # confirm spread across 4 nodes
kubectl -n nginx-demo rollout status deploy/nginx-hello

# Hit the NodePort on any node — you'll see the pod name/IP rotate
# Run in bash shell
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
for i in $(seq 1 12); do curl -s http://${NODE_IP}:30080/ | grep -E 'Pod (name|IP)|Node:'; echo; done

kubectl delete -f tests/nginx-4-instances.yaml  # clean up
```

## Tear down the cluster

```shell
bash run.sh playbooks/delete-cluster.yaml
```

Resets kubeadm, stops kubelet/containerd, and purges packages + CNI config on all nodes. Nodes remain — re-run `install-cluster.yaml` to reinstall.

## Maintenance

- **Patch nodes:** `bash run.sh playbooks/apt-update-upgrade.yaml`
- **Refresh rotated repo signing keys:** `bash run.sh playbooks/refresh-apt-keys.yaml`
- **Rolling reboot:** `bash run.sh playbooks/reboot-hosts.yaml`

`run.sh` flags: `--check` (dry-run), `--syntax-check`, `--debug=true` (-vvvv).

## Logs

Both `run.sh` and `scripts/fetch-kubeconfig.sh` tee their output to `logs/` (gitignored):

- `logs/run-<playbook>-<timestamp>.log` — full terminal output of a playbook run.
- `logs/ansible-<playbook>-<timestamp>.log` — structured Ansible log (set via `ANSIBLE_LOG_PATH`), useful for grep/diagnosis.
- `logs/fetch-kubeconfig-<timestamp>.log` — kubeconfig-fetch trace (includes `set -x` command-by-command).

Each log starts/ends with a banner showing timestamps, args, and exit code. When reporting a failure, attach the relevant file from `logs/`.

## Inventory contract

[inventory/nodes.ini](inventory/nodes.ini) defines groups `control_plane`, `workers`, and `k8s_cluster`. Every playbook here targets `k8s_cluster` (or subgroups). Ansible user is `vm`; SSH key is `inventory/node-ssh-key`.

## Cilium-specific tips

- `cilium status` on the control plane shows agent/operator health at a glance. `cilium connectivity test` runs the official E2E networking tests (ephemeral namespace, a few minutes to complete).
- Hubble (flow observability) is off by default here. See [../cilium-HUBBLE/01-README-HUBBLE.md](../cilium-HUBBLE/01-README-HUBBLE.md) for the post-install enable flow, and [../cilium-HUBBLE/02-README-TRAFFIC-GEN.md](../cilium-HUBBLE/02-README-TRAFFIC-GEN.md) for cross-namespace curl snippets useful for exercising NetworkPolicies.
- The install uses `kubeProxyReplacement=true`, so kube-proxy is disabled by Cilium. If you re-enable kube-proxy later, also flip this flag off.

## Add-ons

Post-install labs live in sibling directories at the repo root: [../metallb-installation/](../metallb-installation/) (LoadBalancer IP allocation), [../registry-installation/](../registry-installation/) (in-cluster Docker registry), [../ingress-nginx-w-certificate/](../ingress-nginx-w-certificate/), [../storage-nfs/](../storage-nfs/), [../keycloak-kubelogin-rbac/](../keycloak-kubelogin-rbac/), [../service-types-examples/](../service-types-examples/), [../pod-probes-examples/](../pod-probes-examples/), and [../controller-crds-operators/](../controller-crds-operators/). Each has its own README.
