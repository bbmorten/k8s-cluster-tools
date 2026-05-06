# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository scope

This repo contains Ansible-driven tooling to stand up a 4-node Kubernetes cluster (1 control plane + 3 workers) on Ubuntu 24.04 with Cilium as the CNI. There is no application code — everything is shell + Ansible YAML.

The active project lives in [k8s-setup-w-cilium/](k8s-setup-w-cilium/). The README references a sibling [../k8s-setup-w-calico/](../k8s-setup-w-calico/) Calico variant; that directory is not in this checkout.

Post-install add-ons live in sibling directories:

- [metallb-installation/](metallb-installation/) — standalone shell scripts that install/tear down MetalLB against an already-built cluster via the merged kubeconfig from `fetch-kubeconfig.sh`. Not Ansible plays.
- [registry-installation/](registry-installation/) — its own self-contained Ansible project (mirrors the `k8s-setup-w-cilium/` shape: `run.sh`, `ansible.cfg`, `inventory/`, `playbooks/`) that installs nerdctl + a Docker registry container on the control plane and wires every node's containerd to use it as an insecure mirror. Has its own `run.sh` and inventory copied from `k8s-setup-w-cilium/inventory/` — keep both in sync if you change IPs.
- [ingress-nginx-w-certificate/](ingress-nginx-w-certificate/) — shell-script lab demo (no SSH to nodes, pure `kubectl apply`) that installs ingress-nginx behind a MetalLB IP and exposes two demo hostnames with different backend TLS modes. Mirrors `metallb-installation/` style.
- [controller-crds-operators/](controller-crds-operators/) — teaching lab that scaffolds a kubebuilder operator (a `Website` CRD whose controller materialises a Deployment + Service + ConfigMap). Two student paths: read [scenario.md](controller-crds-operators/scenario.md) + follow [README.md](controller-crds-operators/README.md) by hand, or run `prereq-check.sh` → `setup-lab.sh` → `demo-magic.sh` → `teardown-lab.sh`. Not Ansible — pure shell + Go via kubebuilder.
- [service-types-examples/](service-types-examples/) — shell-script lab demonstrating the five Service flavors (ClusterIP / NodePort / LoadBalancer / ExternalName / Headless) in the `svc-types-demo` namespace. All selector-based Services share one `web-backend` nginx Deployment. `setup-service-types.sh` applies `manifests/00-…60-` in numeric order; `teardown-service-types.sh` reverses. The LoadBalancer example needs MetalLB; the others don't. Same shape as `metallb-installation/` — uses the caller's current `kubectl` context, no Ansible, no inventory.
- [pod-probes-examples/](pod-probes-examples/) — shell-script lab demonstrating Kubernetes pod probes (liveness / readiness / startup × exec / httpGet / tcpSocket) in the `pod-probes-demo` namespace. `setup-pod-probes.sh` applies `manifests/00-…60-` in numeric order; `teardown-pod-probes.sh` reverses and drops the namespace. Same shape as `service-types-examples/` — pure `kubectl apply`, no node SSH, no Ansible. Uses upstream images `registry.k8s.io/busybox:1.27.2` and `registry.k8s.io/e2e-test-images/agnhost:2.40` only; every Service is `ClusterIP`, so no MetalLB required.
- [cilium-HUBBLE/](cilium-HUBBLE/) — top-level docs-only directory holding [01-README-HUBBLE.md](cilium-HUBBLE/01-README-HUBBLE.md) (post-install Hubble enable flow) and [02-README-TRAFFIC-GEN.md](cilium-HUBBLE/02-README-TRAFFIC-GEN.md) (cross-namespace curl snippets for exercising NetworkPolicies). These were moved here from `k8s-setup-w-cilium/` in commit 49b24c7 — keep that in mind when grepping for `README-HUBBLE.md`.

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

# Switch all nodes' apt sources to a Turkish mirror (archive + security URIs)
bash run.sh playbooks/switch-mirror-tr-w-sec.yaml
bash run.sh playbooks/revert-mirror.yaml      # restore most recent backup

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

**Mirror switching is a separate concern from `apt-update-upgrade.yaml`.** [switch-mirror-tr-w-sec.yaml](k8s-setup-w-cilium/playbooks/switch-mirror-tr-w-sec.yaml) rewrites apt source URIs to a TR mirror — by default `http://tr.archive.ubuntu.com/ubuntu` for **both** archive and security pockets (override via `-e tr_mirror=...` and/or `-e tr_security_mirror=...`). It detects whether the host uses deb822 (`/etc/apt/sources.list.d/ubuntu.sources`, 24.04+) or the legacy `/etc/apt/sources.list` and edits whichever is present. Each run takes a timestamped backup (`ubuntu.sources.bak-<iso8601>` or `sources.list.bak-<iso8601>`) **before** modifying — `force: false` on the backup copy means a single run produces one backup; re-runs do not overwrite earlier backups. A trailing `apt update` task confirms the new mirror is reachable and fails the play if it isn't. [revert-mirror.yaml](k8s-setup-w-cilium/playbooks/revert-mirror.yaml) finds the **most recent** matching `*.bak-*` file (sorted by mtime), saves the current file as a `.pre-revert-<ts>` snapshot, then restores the backup. The two playbooks target `hosts: all`, so they hit every node in the inventory regardless of group.

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

Hubble is **off by default**. See [cilium-HUBBLE/01-README-HUBBLE.md](cilium-HUBBLE/01-README-HUBBLE.md) for the post-install enable flow (`cilium hubble enable --ui` → `cilium hubble port-forward &`). [cilium-HUBBLE/02-README-TRAFFIC-GEN.md](cilium-HUBBLE/02-README-TRAFFIC-GEN.md) has cross-namespace curl snippets useful for exercising NetworkPolicies and watching flows.

## MetalLB (LoadBalancer support)

Cilium's install does **not** provide LoadBalancer IP allocation, so Services of `type: LoadBalancer` stay `<pending>` out of the box. [metallb-installation/setup-metallb.sh](metallb-installation/setup-metallb.sh) applies the upstream `metallb-native.yaml` manifest (pinned to `v0.15.3`), waits on the controller/speaker pods, then creates an `IPAddressPool` (`first-pool`, range `192.168.48.201-192.168.48.205`) and an `L2Advertisement`. The address range is on the same `192.168.48.0/24` subnet as the nodes (`.31-.34`), which is required for L2 mode — the speaker ARPs for these IPs from the nodes themselves. The script also creates a stub `test-service` whose selector matches no pods; this is just to confirm IP allocation by `kubectl get svc`.

[metallb-installation/teardown-metallb.sh](metallb-installation/teardown-metallb.sh) reverses the install in order (test-service → L2Advertisement → IPAddressPool → manifest delete), then `kubectl wait --for=delete namespace/metallb-system` and verifies no `metallb.io` CRDs remain. Both scripts use the caller's current kubeconfig context — point at the cluster via `fetch-kubeconfig.sh` first.

To bump the MetalLB version, edit the `v0.15.3` URL in **both** scripts (`setup-metallb.sh` line 7 and `teardown-metallb.sh`'s `METALLB_MANIFEST` variable) so teardown deletes what setup applied.

## In-cluster registry (registry-installation/)

[registry-installation/](registry-installation/) is its own Ansible project — `cd registry-installation && bash run.sh playbooks/install-registry.yaml`. Versions pinned inline in [playbooks/install-registry.yaml](registry-installation/playbooks/install-registry.yaml): nerdctl `2.2.2`, registry image `registry:3.1.1`. To bump versions, edit the `nerdctl_version` / `registry_image` vars in install **and** the matching `registry:3.1.1` line in [playbooks/teardown-registry.yaml](registry-installation/playbooks/teardown-registry.yaml) so teardown removes what install applied.

**Two plays.** Play 1 (control plane only) downloads the nerdctl tarball, extracts only the `nerdctl` binary into `/usr/local/bin/`, pulls `registry:3.1.1`, then runs the registry as `nerdctl run -d --name registry --restart=always --net=host -v /var/lib/registry:/var/lib/registry registry:3.1.1`. Play 2 (every node) writes `/etc/containerd/certs.d/<cp-ip>:5000/hosts.toml` as **HTTP-only** (`server = "http://<cp-ip>:5000"` plus a matching `[host."http://<cp-ip>:5000"]` block with just `capabilities = ["pull","resolve","push"]` — no `skip_verify`/`ca`/`client`, since those are TLS knobs and meaningless under `http://`), then **flips a single line** in `/etc/containerd/config.toml`: `config_path = ""` → `config_path = "/etc/containerd/certs.d"`. It does **not** regenerate `config.toml` from `containerd config default` — that would wipe the `SystemdCgroup = true` line set by `install-cluster.yaml` and cause kubelet/containerd cgroup-driver mismatches.

**Why `--net=host`.** nerdctl's default bridge mode drops `nerdctl-bridge.conflist` into `/etc/cni/net.d/`, which on a Cilium node sits next to `05-cilium.conflist` and can break pod networking. Host networking sidesteps the CNI machinery — the registry just listens on `:5000` directly on the control plane.

**Public registries keep working.** The `certs.d/<host:port>/` layout is per-host: containerd only consults it when pulling from that exact `host:port`. `docker.io`, `registry.k8s.io`, etc. continue to use normal HTTPS. Don't create a `_default/hosts.toml` or a `registry.mirrors."docker.io"` block unless you actually want to intercept those.

**Interactive `nerdctl` needs `sudo`.** As non-root, nerdctl tries to talk to a per-user rootless containerd at `/run/user/$UID/containerd-rootless` (which doesn't exist here). The system containerd's socket at `/run/containerd/containerd.sock` is root-only. The playbook itself works because every nerdctl task runs under `become: true`.

**Teardown order matters.** [playbooks/teardown-registry.yaml](registry-installation/playbooks/teardown-registry.yaml) reverses install in this order to keep containerd healthy: (1) all nodes — reset `config_path` to `""`, remove the `certs.d/<cp-ip>:5000/` directory, restart containerd; (2) control plane — `nerdctl stop/rm/rmi registry:3.1.1`; (3) delete `/var/lib/registry` (destroys blob store); (4) delete `/usr/local/bin/nerdctl` unless `-e remove_nerdctl=false`. Each step gracefully no-ops on hosts where the install never ran.

## Ingress-nginx demo (ingress-nginx-w-certificate/)

[ingress-nginx-w-certificate/](ingress-nginx-w-certificate/) is a self-contained lab that exposes two hostnames behind a MetalLB-assigned LoadBalancer IP, with **different** backend TLS modes per host: `test-ingress-1.example.com/{a,b,c}` terminates TLS at the ingress and talks plain HTTP to pods in `test-ingress-1`; `test-ingress-2.example.com/{a,b,c}` re-encrypts and talks HTTPS to pods in `test-ingress-2`. Each path (`/a`, `/b`, `/c`) routes to a distinct backend Deployment (`web-a`, `web-b`, `web-c`); the response identifies the pod via Downward-API env vars rendered into the nginx config.

**Versions.** Controller pinned to `controller-v1.15.1` — **the final release**. The upstream `kubernetes/ingress-nginx` repo was archived **2026-03-24**. Bump via `INGRESS_NGINX_VERSION=...` env var (set in both [setup-ingress-demo.sh](ingress-nginx-w-certificate/setup-ingress-demo.sh) and [teardown-ingress-demo.sh](ingress-nginx-w-certificate/teardown-ingress-demo.sh)). Successors to consider: Ingate, or Cilium's own Gateway API implementation.

**Re-encrypt, not passthrough.** test-ingress-2 uses `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` (controller decrypts, inspects path, re-encrypts to upstream). Full SSL passthrough was rejected because it routes only by SNI — the controller never sees the path, so `/a /b /c` fan-out wouldn't work. Upstream cert verification is left at the default (off) because the pod cert is self-signed by the same script that issues the edge cert.

**One SAN cert, two namespaces.** [create-tls-secret.sh](ingress-nginx-w-certificate/create-tls-secret.sh) generates a single cert with `subjectAltName = DNS:test-ingress-1.example.com, DNS:test-ingress-2.example.com` and applies the same `example-tls` Secret in both namespaces (used both by the Ingress `tls:` blocks and mounted into test-ingress-2 pods that serve TLS themselves). The script is re-runnable via `kubectl create secret … --dry-run=client -o yaml | kubectl apply`.

**LB IP pinning + the conflict gotcha.** Setup pins the controller Service to `192.168.48.201` via the `metallb.universe.tf/loadBalancerIPs` annotation so external `/etc/hosts` entries survive teardown/reinstall. **MetalLB will not double-allocate** — if `metallb-installation/setup-metallb.sh`'s leftover `test-service` (in `default`) is still holding `.201`, the controller Service will sit without an EXTERNAL-IP and setup prints `WARNING: controller Service has no LB IP yet`. Fix: `kubectl delete svc test-service -n default` (the stub serves no purpose), or override `LB_IP=192.168.48.202`.

**Pod identification via `NGINX_ENVSUBST_FILTER`.** The nginx image's templating runs `envsubst` over `/etc/nginx/templates/*.template`; without a filter it would clobber nginx variables like `$host`, `$request_uri`, `$scheme` (substituting them to empty). Backends set `NGINX_ENVSUBST_FILTER="POD_NAME|POD_NAMESPACE|SERVICE_LABEL"` so only those three Downward-API/static env vars get expanded; nginx's own `$vars` pass through verbatim and are evaluated at request time.

**Teardown order.** [teardown-ingress-demo.sh](ingress-nginx-w-certificate/teardown-ingress-demo.sh) deletes ingresses → backends → TLS Secrets → demo namespaces → controller manifest, in that order so the controller stops routing into namespaces before they disappear.

## Operator lab (controller-crds-operators/)

[controller-crds-operators/](controller-crds-operators/) builds a `Website` operator with kubebuilder: API group `web.example.com`, kind `Website`, controller materialises an nginx Deployment + Service + ConfigMap from `spec.html` / `spec.replicas` / `spec.image`. Tools required: `go >= 1.23`, `kubebuilder >= v4.0` (tested against v4.14), `kubectl`, `make`. The basic lab path uses `make run` and needs **no** container runtime; image-build targets honour `CONTAINER_TOOL=nerdctl|podman|docker`.

**Two student paths.** [README.md](controller-crds-operators/README.md) documents both: (a) hand-scaffold via `kubebuilder init && create api`, paste in the solution files, `make install run`; (b) lazy path via `prereq-check.sh` → `setup-lab.sh` → `demo-magic.sh` → `teardown-lab.sh`. The lazy path scaffolds the project, copies [solution/website_types.go](controller-crds-operators/solution/website_types.go) and [solution/website_controller.go](controller-crds-operators/solution/website_controller.go) over the kubebuilder defaults, and applies a sample CR. The scaffolded project lands in `controller-crds-operators/website-operator/` (gitignored).

**`setup-lab.sh` deliberately does not start the controller.** `make run` is foreground — students should see the reconcile log live. Backgrounding it would also complicate teardown (no PID to stop). The script ends with explicit instructions: open a second terminal, `cd website-operator && make run`.

**The solution Go files fix two bugs in scenario.md's sample code** that would prevent `go build` from working: (1) the scenario shows `Scheme *runtime.Scheme` but only adds the `runtime` import as a separate footnote — solution puts it in the import block; (2) the scenario imports `k8s.io/apimachinery/pkg/api/errors` but never uses it — solution drops it. If you regenerate the solution from the scenario, re-apply both fixes.

**`prereq-check.sh`'s container-runtime warning must stay single-quoted.** The text contains `` `make docker-build` ``; under double quotes, bash command-substitutes the backticks and actually runs `make docker-build` (which prints `No rule to make target 'docker-build'. Stop.` because there's no Makefile in CWD yet). Detection order is docker → nerdctl → podman to match what this repo installs via [registry-installation/](registry-installation/).

**Re-runnable from any state.** `setup-lab.sh` `rm -rf`'s `${LAB_DIR}` before scaffolding, so a half-finished previous run is no problem. `teardown-lab.sh` deletes Website CRs cluster-wide → `make uninstall` → fallback `kubectl delete crd` → remove scaffold dir; each step gracefully no-ops if the prior install never happened. Override `LAB_DIR=...` on either to use a different scaffold location.

**Versioning.** Pinned via env-var defaults in [setup-lab.sh](controller-crds-operators/setup-lab.sh): `DOMAIN=example.com`, `REPO=github.com/example/website-operator`. **If you change `DOMAIN` or `REPO`**, the import path `github.com/example/website-operator/api/v1` and the `web.example.com` group string baked into [solution/website_controller.go](controller-crds-operators/solution/website_controller.go) (in imports + `+kubebuilder:rbac` markers) will not match — edit the solution file too. There's no shared constant.

## Pod probes lab (pod-probes-examples/)

[pod-probes-examples/](pod-probes-examples/) is a teaching lab for `livenessProbe` / `readinessProbe` / `startupProbe`. Same shape as [service-types-examples/](service-types-examples/) — `setup-pod-probes.sh` applies [manifests/](pod-probes-examples/manifests/) in numeric order (`00..60`), `teardown-pod-probes.sh` deletes in reverse and drops the `pod-probes-demo` namespace. Versions pinned per-manifest, not in a shared variable: `registry.k8s.io/busybox:1.27.2` (10/40/50) and `registry.k8s.io/e2e-test-images/agnhost:2.40` (20/30/60). To bump, grep `image:` under `manifests/` and update each occurrence.

**Several manifests have load-bearing "wrong-looking" choices that are the actual teaching point — don't soften them:**

- **[20-liveness-http.yaml](pod-probes-examples/manifests/20-liveness-http.yaml) restart-loops forever.** `agnhost liveness` is *designed* to flip `/healthz` from 200 → 500 ~10s after each container start, so the probe fails, the kubelet restarts the container, and the cycle repeats. That perpetual restart loop is the demo. Don't "fix" it by switching to `agnhost netexec` or pointing the probe at `/`; you'd lose the lesson.
- **[50-startup-and-liveness.yaml](pod-probes-examples/manifests/50-startup-and-liveness.yaml) sets `livenessProbe.failureThreshold: 1` deliberately.** Without the startup probe in front of it, the pod would die on the first liveness probe at t≈5s (long before the simulated app finishes booting at t=30s). The whole point is to demonstrate that the startup probe *suppresses* liveness/readiness until it succeeds. Removing the startup block in this file should cause an immediate kill — that's a valid student exercise. Don't "soften" the liveness threshold to hide the demo.
- **[60-combined-deployment.yaml](pod-probes-examples/manifests/60-combined-deployment.yaml) probes hit `path: /`, not `/healthz`.** `agnhost netexec` reliably returns 200 on `/`; the `/healthz` path is only present in `agnhost liveness` mode (used by `20-liveness-http.yaml`). If you change the args away from `netexec`, also update the probe path or it'll 404.
- **[40-readiness-exec.yaml](pod-probes-examples/manifests/40-readiness-exec.yaml)'s Service has no real backend.** The pod is busybox running `sleep 600` — it doesn't actually serve port 80. The Service `readiness-demo` exists *only* so students can run `kubectl get endpointslices -l kubernetes.io/service-name=readiness-demo -w` and watch the pod's IP join/leave the EndpointSlice as readiness flips. Adding a real `targetPort` that the pod serves would obscure the demo, not improve it.

**No MetalLB / ingress dependency.** Every Service is `ClusterIP` and the lab is meant to be self-contained on a vanilla Cilium cluster. Don't add `type: LoadBalancer` examples here — that's `service-types-examples/`'s job.
