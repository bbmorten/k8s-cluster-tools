# registry-installation-https

Stand up an in-cluster **OCI registry (`registry:3`) on the control-plane node with HTTPS** and a self-signed certificate, then configure every node's containerd to verify the registry against that certificate. **No `insecure_skip_verify` / `--insecure-tls` anywhere.**

This is the TLS-clean variant of [../registry-installation/](../registry-installation/) (which serves over plain HTTP). Same Ansible shape, same inventory contract, same `run.sh` wrapper. Both labs can coexist on disk; do **not** run them at the same time against one cluster — they fight over `/etc/containerd/certs.d/<cp-ip>:5000/` and `config.toml`.

Ported from the shell-script lab at `sites/kubess/public/files/Roadmap/02-common-registry/{01,02,03}-*.sh` + `image-mirror.sh`.

## Layout

```
registry-installation-https/
├── ansible.cfg                  # points ansible at inventory/nodes.ini
├── run.sh                       # wrapper: ansible-playbook -b -K <file> [--check|--syntax-check|--debug=true]
├── inventory/
│   ├── nodes.ini                # same hosts as k8s-setup-w-cilium / registry-installation
│   ├── node-ssh-key             # 0600
│   └── node-ssh-key.pub
└── playbooks/
    ├── install-registry.yaml    # cert + nerdctl + registry:3 + per-node trust
    ├── teardown-registry.yaml   # reverses install (workload-only by default)
    └── mirror-image.yaml        # pull a public image and push it to the in-cluster registry
```

## Prerequisites

- A cluster already built by [../k8s-setup-w-cilium/playbooks/install-cluster.yaml](../k8s-setup-w-cilium/playbooks/install-cluster.yaml). containerd + `/etc/containerd/config.toml` must exist on every node — install fails fast if not.
- The same SSH key + `vm` user as the cluster install. The `inventory/` here is a copy of the one in `k8s-setup-w-cilium/`; if you change IPs in one, change all three (cilium, registry-installation, registry-installation-https).
- Ansible on the workstation running `run.sh`.

## Versions

Pinned inline in [playbooks/install-registry.yaml](playbooks/install-registry.yaml):

- nerdctl **1.7.7** (final 1.x release — see "Why not nerdctl 2.x?" below)
- registry image **registry:3.1.1**
- Self-signed cert validity **825 days** (`cert_days` var)

To bump versions, edit the `nerdctl_version` / `registry_image` vars in install **and** the matching `registry_image` in [playbooks/teardown-registry.yaml](playbooks/teardown-registry.yaml) so cleanup deletes the right image.

## Usage

```shell
cd registry-installation-https

# Dry-run / syntax checks
bash run.sh playbooks/install-registry.yaml --syntax-check
bash run.sh playbooks/install-registry.yaml --check

# Install: cert + registry on control plane, trust on every node
bash run.sh playbooks/install-registry.yaml

# Mirror a public image into the in-cluster registry
bash run.sh playbooks/mirror-image.yaml -e image=nginx:1.27
bash run.sh playbooks/mirror-image.yaml -e image=alpine -e tag=3.20
bash run.sh playbooks/mirror-image.yaml -e image=ghcr.io/some/repo:v1

# Tear down (keeps /srv/registry/data so re-install reuses pushed images)
bash run.sh playbooks/teardown-registry.yaml

# Tear down and wipe pushed images
bash run.sh playbooks/teardown-registry.yaml -e wipe_data=true

# Tear down but keep the nerdctl binary
bash run.sh playbooks/teardown-registry.yaml -e remove_nerdctl=false
```

`run.sh` flags: `--check` (dry-run), `--syntax-check`, `--debug=true` (-vvvv). Output is teed to `logs/run-<playbook>-<ts>.log` plus a structured Ansible log alongside.

## What the install playbook does

**Play 1 — control plane only:**

1. Installs nerdctl `1.7.7` to `/usr/local/bin/` (idempotent — skips if already present at the right version).
2. Creates `/srv/registry/certs` + `/srv/registry/data`.
3. `openssl req` generates a single self-signed cert with `CN={{ short_hostname }}` and SANs `DNS:<short_hostname>, DNS:localhost, IP:<cp_ip>, IP:127.0.0.1`. Idempotent via `creates:` — re-runs do not regenerate. Delete `domain.crt` to force a new cert.
4. `nerdctl pull registry:3.1.1`.
5. `nerdctl run -d --name private-registry --restart=always --net=host -v /srv/registry/data:/var/lib/registry -v /srv/registry/certs:/certs:ro -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key registry:3.1.1`. Idempotent.
6. Probes `https://localhost:5000/v2/` with the CA file until 200.
7. Slurps `domain.crt` so play 2 can copy it everywhere.

**Play 2 — every node in `k8s_cluster`:**

1. Creates `/etc/containerd/certs.d/<cp-ip>:5000/` and `/etc/containerd/certs.d/<cp-name>:5000/`.
2. Drops the same `ca.crt` and a `hosts.toml` under each, declaring the registry as `https://...` with `capabilities = ["pull", "resolve", "push"]` and `ca = "/etc/containerd/certs.d/<endpoint>/ca.crt"`. Both forms verify against the same CA.
3. Edits `/etc/containerd/config.toml` in place: flips `config_path` to `/etc/containerd/certs.d`. **Nothing else is touched** — `SystemdCgroup = true` set by `install-cluster.yaml` is preserved.
4. Adds `<cp-ip> <cp-name>` to `/etc/hosts` inside an Ansible-managed block so the name form resolves.
5. `systemctl restart containerd` (handler).
6. Probes `https://<cp-ip>:5000/v2/` and `https://<cp-name>:5000/v2/` from each node and reports OK/FAIL per host per form.

## Design notes

**Why nerdctl 1.7.7 (not 2.x)?** nerdctl 2.x has [containerd/nerdctl#4461](https://github.com/containerd/nerdctl/issues/4461): it eagerly tries to create a default CNI bridge network *even when launched with `--net=host`* and looks for `/opt/cni/bin/bridge`. On a Cilium node only Cilium's CNI binaries live there, so `nerdctl run` hangs on CNI initialisation. nerdctl 1.7.7's release notes state it is "expected to be used with containerd v1.6 or v1.7"; Ubuntu 24.04 ships containerd 1.7.28. Stay on the 1.7 line until #4461 closes upstream.

**Why `--net=host` (not `-p 5000:5000`)?** The source shell script publishes the port with `-p`, which on nerdctl 1.x **also** requires the bridge CNI plugin and writes `nerdctl-bridge.conflist` into `/etc/cni/net.d/`. On a Cilium node that conflist sits next to `05-cilium.conflist` and breaks pod networking. `--net=host` bypasses CNI entirely; the registry just listens on `:5000` of the control-plane host. Net-effect on the cluster is identical (registry reachable at `<cp-ip>:5000` over TLS) — only the namespace topology differs.

**Why `certs.d/<host>/hosts.toml` instead of rewriting `config.toml`?** It's the modern containerd pattern (>=1.5). It only requires flipping a single string (`config_path`) inside `config.toml`; the per-registry settings live in their own files. Regenerating `config.toml` from `containerd config default` would silently wipe the `SystemdCgroup = true` setting from the cluster install and cause kubelet/containerd cgroup-driver mismatches.

**Why two endpoint keys (IP and name)?** containerd matches the connection target byte-for-byte against the directory under `certs.d/`. If a Pod references the registry by IP and another by hostname, both must have a matching directory or the second pull fails with `http: server gave HTTP response to HTTPS client` (or worse, gets routed differently). Both keys point at the same CA file and the cert SANs cover both forms.

**Why TLS-clean instead of `insecure_skip_verify`?** That flag exists, and would be one line shorter. But it normalises "skip verification" as a habit, which is exactly the wrong instinct for students preparing to operate real clusters. The cost here is one openssl invocation and one `ca = ...` line in `hosts.toml`; the payoff is that students see the full TLS-anchoring chain — cert with proper SANs, CA file shipped to every node, containerd verifying every pull — and understand which knob enables which property.

## Coexistence with `../registry-installation/`

Both projects target the same `<cp-ip>:5000` endpoint key under `/etc/containerd/certs.d/`, but write different content there (HTTP vs HTTPS) and flip the same `config_path` in `config.toml`. Running both installs back-to-back on the same cluster will leave whichever ran last in charge.

If you've previously run `../registry-installation/` on this cluster, run its teardown first:

```shell
( cd ../registry-installation && bash run.sh playbooks/teardown-registry.yaml )
```

Then run this lab's install. Same in reverse if you switch back.

## Verifying the registry

From the workstation (with `kubectl` pointed at the cluster) or from any node:

```shell
CP_IP=$(awk '/^[a-zA-Z0-9_-]+ ansible_host/ {print $2}' inventory/nodes.ini | head -1 | cut -d= -f2)
CP_NAME=$(awk '/^[a-zA-Z0-9_-]+ ansible_host/ {print $1}' inventory/nodes.ini | head -1)

# Pull the CA so curl on the workstation can also verify
ssh vm@${CP_IP} 'sudo cat /srv/registry/certs/domain.crt' > /tmp/registry-ca.crt

# Registry HTTP API over TLS (no -k)
curl --cacert /tmp/registry-ca.crt https://${CP_IP}:5000/v2/ && echo OK
curl --cacert /tmp/registry-ca.crt https://${CP_IP}:5000/v2/_catalog

# Push via the playbook helper
bash run.sh playbooks/mirror-image.yaml -e image=alpine:3.20

# Pull through containerd (on any node) using crictl — verifies kubelet path
ssh vm@${CP_IP} "sudo crictl pull ${CP_IP}:5000/alpine:3.20"

# End-to-end: kubelet pulls and runs from the local registry
kubectl run alpine-test -it --rm --image=${CP_IP}:5000/alpine:3.20 -- /bin/sh
```

If `crictl pull` fails with `x509: certificate signed by unknown authority`, the node missed play 2 — re-run install or check `/etc/containerd/certs.d/${CP_IP}:5000/ca.crt` exists and `hosts.toml` references it. If it fails with `cannot validate certificate for ... because it doesn't contain any IP SANs`, the cert was generated wrong — `rm /srv/registry/certs/domain.{crt,key}` on the control plane and re-run install.

## Teardown order

[playbooks/teardown-registry.yaml](playbooks/teardown-registry.yaml) reverses install in this order to keep containerd healthy:

1. **All nodes** (first, so kubelet stops trying to reach the registry over TLS while we tear it down): reset `config_path` to `""`, remove the `certs.d/<endpoint>/` directories (both forms), remove the `/etc/hosts` block, restart containerd.
2. **Control plane**: `nerdctl stop/rm private-registry` → `nerdctl rmi registry:3.1.1` → delete `/srv/registry/certs`.
3. **Control plane**: delete `/srv/registry/data` only when `-e wipe_data=true`. Default keeps it so a re-install reuses pushed images.
4. **Control plane**: delete `/usr/local/bin/nerdctl` unless `-e remove_nerdctl=false`.

The teardown gracefully no-ops on hosts where the install never ran.

## Logs

`run.sh` tees every invocation to `logs/` (gitignored), same convention as `k8s-setup-w-cilium/`:

- `logs/run-<playbook>-<ts>.log` — full terminal output
- `logs/ansible-<playbook>-<ts>.log` — structured Ansible log via `ANSIBLE_LOG_PATH`
