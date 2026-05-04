# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository scope

This repo contains Ansible-driven tooling to stand up a 4-node Kubernetes cluster (1 control plane + 3 workers) on Ubuntu 24.04 with Cilium as the CNI. There is no application code — everything is shell + Ansible YAML.

The active project lives in [k8s-setup-w-cilium/](k8s-setup-w-cilium/). The README references a sibling [../k8s-setup-w-calico/](../k8s-setup-w-calico/) Calico variant; that directory is not in this checkout.

Post-install add-ons live in sibling directories:

- [metallb-installation/](metallb-installation/) — standalone shell scripts that install/tear down MetalLB against an already-built cluster via the merged kubeconfig from `fetch-kubeconfig.sh`. Not Ansible plays.
- [registry-installation/](registry-installation/) — its own self-contained Ansible project (mirrors the `k8s-setup-w-cilium/` shape: `run.sh`, `ansible.cfg`, `inventory/`, `playbooks/`) that installs nerdctl + a Docker registry container on the control plane and wires every node's containerd to use it as an insecure mirror. Has its own `run.sh` and inventory copied from `k8s-setup-w-cilium/inventory/` — keep both in sync if you change IPs.

## Where commands run

**All commands must be run from inside `k8s-setup-w-cilium/`** — both [run.sh](k8s-setup-w-cilium/run.sh) and [scripts/fetch-kubeconfig.sh](k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh) resolve paths relative to `$PWD` (e.g. `inventory/node-ssh-key`). [ansible.cfg](k8s-setup-w-cilium/ansible.cfg) points at `inventory/nodes.ini` as a relative path.

## Common commands

```shell
# Bootstrap fresh hosts (creates user `vm`, installs SSH key, grants passwordless sudo)
bash scripts/bootstrap-nodes.sh

# Patch all nodes
bash run.sh playbooks/apt-update-upgrade.yaml

# Full cluster install (containerd + kubeadm + Cilium)
bash run.sh playbooks/install-cluster.yaml

# Tear down (kubeadm reset + purge packages/CNI config; nodes themselves remain)
bash run.sh playbooks/delete-cluster.yaml

# Maintenance
bash run.sh playbooks/refresh-apt-keys.yaml   # rotate Trivy/Falco signing keys
bash run.sh playbooks/reboot-hosts.yaml       # rolling reboot

# Pull admin kubeconfig to workstation (merges into ~/.kube/config by default)
bash scripts/fetch-kubeconfig.sh
bash scripts/fetch-kubeconfig.sh --standalone ~/.kube/cilium-lab.conf
```

`run.sh` flags: `--check` (dry-run), `--syntax-check`, `--debug=true` (-vvvv).

## Architecture

**Single source of truth: [inventory/nodes.ini](k8s-setup-w-cilium/inventory/nodes.ini).** Defines groups `control_plane`, `workers`, and `k8s_cluster` (union). Every playbook targets `k8s_cluster` or a subgroup. Ansible user is `vm`; SSH key is `inventory/node-ssh-key`. Default IPs are `192.168.48.31-34`.

**[install-cluster.yaml](k8s-setup-w-cilium/playbooks/install-cluster.yaml) is one big sequenced playbook** with 7 plays in this order: (1) populate `/etc/hosts` from inventory; (2) apt update/upgrade + disable swap; (3) install kernel modules, containerd, kubelet/kubeadm/kubectl from `pkgs.k8s.io/core:/stable:/v1.32`; (4) install crictl from kubernetes-sigs/cri-tools latest release; (5) `kubeadm init` on control plane with a generated `/tmp/kubeadm-config.yaml` (cgroupDriver=systemd, advertiseAddress=control plane IP); (6) install Cilium via the `cilium` CLI on the control plane with `kubeProxyReplacement=true` (so kube-proxy is **disabled**); (7) workers fetch the join command via `delegate_to: control_plane` and run it. Most steps are idempotent via `creates:` or `stat` guards.

**The `containerd` package lives in Ubuntu's `universe` repo.** Play (3) explicitly enables `universe` before `apt install containerd` because cloud images can ship with main-only sources, in which case the install fails with "No package matching 'containerd' is available". The enable step first greps `/etc/apt/sources.list.d/ubuntu.sources` (deb822) for an existing `universe` component and **only invokes `apt_repository` if it's missing** — otherwise the one-line file `apt_repository` writes (`archive_ubuntu_com_ubuntu.list`) duplicates the deb822 entry and apt warns "Target ... is configured multiple times". The same play also removes that legacy `.list` if it was created by an earlier run.

**[apt-update-upgrade.yaml](k8s-setup-w-cilium/playbooks/apt-update-upgrade.yaml) does not touch apt sources.** It mirrors the apt update/upgrade pattern from `install-cluster.yaml` play (2): wait on apt locks (lsof loop), `update_cache` and `upgrade: full` (with `force_apt_get: yes`, `autoremove`, `autoclean`), each retried 5×. Whatever mirror the node is configured against is used as-is — if a mirror is unreachable, fix it on the node (or re-add a `replace:` task here). Unlike install-cluster.yaml's update step it deliberately omits `cache_valid_time`: this is the "patch the nodes" tool, so always re-fetch indices even if another step refreshed them minutes ago — without that, a 12-minute-old cache that happened to be incomplete will silently report "0 upgraded" and miss real security updates. Pass `-e perform_reboot=yes` to actually reboot when `/var/run/reboot-required` is set; otherwise the playbook only reports it.

**Versions are pinned inline.** To bump, edit [install-cluster.yaml](k8s-setup-w-cilium/playbooks/install-cluster.yaml): `kubernetes_version` (1.32.2), `cilium_version` (1.16.5), `cilium_cli_version` (v0.16.24), plus the two `v1.32` strings in the apt repo URL/path. Pod CIDR `10.244.0.0/16`, service CIDR `10.96.0.0/12`.

**fetch-kubeconfig.sh's renaming step is load-bearing, not cosmetic.** kubeadm always names its cluster/user/context `kubernetes`/`kubernetes-admin`. If you merge two kubeadm kubeconfigs without renaming, `kubectl config view --flatten` keeps the **first** cluster entry's CA against the new server URL, producing `x509: certificate signed by unknown authority`. The script renames to `cilium-lab` / `cilium-lab-admin` and also deletes any stale `kubernetes`/`cilium-lab` entries before merging.

**Re-enabling kube-proxy requires also flipping Cilium's flag.** The install sets `kubeProxyReplacement=true`; if kube-proxy is brought back later, Cilium must be reconfigured.

## Logging

Both `run.sh` and `scripts/fetch-kubeconfig.sh` tee output to `logs/` (gitignored):
- `logs/run-<playbook>-<timestamp>.log` — full terminal output
- `logs/ansible-<playbook>-<timestamp>.log` — structured Ansible log via `ANSIBLE_LOG_PATH`
- `logs/fetch-kubeconfig-<timestamp>.log` — includes `set -x` traces

Each log opens/closes with a banner showing args + exit code. Reference these when diagnosing failures.

## Smoke test

[tests/nginx-4-instances.yaml](k8s-setup-w-cilium/tests/nginx-4-instances.yaml) deploys 4 nginx replicas (one per node via `topologySpreadConstraints`) behind a NodePort on `30080`. Each pod uses the Downward API to render its name/IP/node, so `curl` in a loop reveals load-balancing behavior.

## Hubble / traffic generation

Hubble is **off by default**. See [README-HUBBLE.md](k8s-setup-w-cilium/README-HUBBLE.md) for the post-install enable flow (`cilium hubble enable --ui` → `cilium hubble port-forward &`). [README-TRAFFIC-GEN.md](k8s-setup-w-cilium/README-TRAFFIC-GEN.md) has cross-namespace curl snippets useful for exercising NetworkPolicies and watching flows.

## MetalLB (LoadBalancer support)

Cilium's install does **not** provide LoadBalancer IP allocation, so Services of `type: LoadBalancer` stay `<pending>` out of the box. [metallb-installation/setup-metallb.sh](metallb-installation/setup-metallb.sh) applies the upstream `metallb-native.yaml` manifest (pinned to `v0.15.3`), waits on the controller/speaker pods, then creates an `IPAddressPool` (`first-pool`, range `192.168.48.201-192.168.48.205`) and an `L2Advertisement`. The address range is on the same `192.168.48.0/24` subnet as the nodes (`.31-.34`), which is required for L2 mode — the speaker ARPs for these IPs from the nodes themselves. The script also creates a stub `test-service` whose selector matches no pods; this is just to confirm IP allocation by `kubectl get svc`.

[metallb-installation/teardown-metallb.sh](metallb-installation/teardown-metallb.sh) reverses the install in order (test-service → L2Advertisement → IPAddressPool → manifest delete), then `kubectl wait --for=delete namespace/metallb-system` and verifies no `metallb.io` CRDs remain. Both scripts use the caller's current kubeconfig context — point at the cluster via `fetch-kubeconfig.sh` first.

To bump the MetalLB version, edit the `v0.15.3` URL in **both** scripts (`setup-metallb.sh` line 7 and `teardown-metallb.sh`'s `METALLB_MANIFEST` variable) so teardown deletes what setup applied.

## In-cluster registry (registry-installation/)

[registry-installation/](registry-installation/) is its own Ansible project — `cd registry-installation && bash run.sh playbooks/install-registry.yaml`. Versions pinned inline in [playbooks/install-registry.yaml](registry-installation/playbooks/install-registry.yaml): nerdctl `2.2.2`, registry image `registry:3.1.1`. To bump versions, edit the `nerdctl_version` / `registry_image` vars in install **and** the matching `registry:3.1.1` line in [playbooks/teardown-registry.yaml](registry-installation/playbooks/teardown-registry.yaml) so teardown removes what install applied.

**Two plays.** Play 1 (control plane only) downloads the nerdctl tarball, extracts only the `nerdctl` binary into `/usr/local/bin/`, pulls `registry:3.1.1`, then runs the registry as `nerdctl run -d --name registry --restart=always --net=host -v /var/lib/registry:/var/lib/registry registry:3.1.1`. Play 2 (every node) writes `/etc/containerd/certs.d/<cp-ip>:5000/hosts.toml` with `skip_verify = true`, then **flips a single line** in `/etc/containerd/config.toml`: `config_path = ""` → `config_path = "/etc/containerd/certs.d"`. It does **not** regenerate `config.toml` from `containerd config default` — that would wipe the `SystemdCgroup = true` line set by `install-cluster.yaml` and cause kubelet/containerd cgroup-driver mismatches.

**Why `--net=host`.** nerdctl's default bridge mode drops `nerdctl-bridge.conflist` into `/etc/cni/net.d/`, which on a Cilium node sits next to `05-cilium.conflist` and can break pod networking. Host networking sidesteps the CNI machinery — the registry just listens on `:5000` directly on the control plane.

**Public registries keep working.** The `certs.d/<host:port>/` layout is per-host: containerd only consults it when pulling from that exact `host:port`. `docker.io`, `registry.k8s.io`, etc. continue to use normal HTTPS. Don't create a `_default/hosts.toml` or a `registry.mirrors."docker.io"` block unless you actually want to intercept those.

**Interactive `nerdctl` needs `sudo`.** As non-root, nerdctl tries to talk to a per-user rootless containerd at `/run/user/$UID/containerd-rootless` (which doesn't exist here). The system containerd's socket at `/run/containerd/containerd.sock` is root-only. The playbook itself works because every nerdctl task runs under `become: true`.

**Teardown order matters.** [playbooks/teardown-registry.yaml](registry-installation/playbooks/teardown-registry.yaml) reverses install in this order to keep containerd healthy: (1) all nodes — reset `config_path` to `""`, remove the `certs.d/<cp-ip>:5000/` directory, restart containerd; (2) control plane — `nerdctl stop/rm/rmi registry:3.1.1`; (3) delete `/var/lib/registry` (destroys blob store); (4) delete `/usr/local/bin/nerdctl` unless `-e remove_nerdctl=false`. Each step gracefully no-ops on hosts where the install never ran.
