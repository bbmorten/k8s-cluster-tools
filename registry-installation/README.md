# registry-installation

Stand up an in-cluster **Docker Registry v3** on the control plane node and wire every node's containerd to pull from it as an insecure HTTP mirror.

This folder is a self-contained Ansible project. It mirrors the layout of [../k8s-setup-w-cilium/](../k8s-setup-w-cilium/) and uses the same inventory contract — every command runs from inside this folder.

## Layout

```
registry-installation/
├── ansible.cfg                  # points ansible at inventory/nodes.ini
├── run.sh                       # wrapper: ansible-playbook -b -K <file> [--check|--syntax-check|--debug=true]
├── inventory/
│   ├── nodes.ini                # same hosts as k8s-setup-w-cilium
│   ├── node-ssh-key             # 0600
│   └── node-ssh-key.pub
└── playbooks/
    ├── install-registry.yaml    # nerdctl + registry container + containerd mirror config
    └── teardown-registry.yaml   # reverses install (config, container, image, data, nerdctl)
```

## Prerequisites

- A Kubernetes cluster already built by [../k8s-setup-w-cilium/playbooks/install-cluster.yaml](../k8s-setup-w-cilium/playbooks/install-cluster.yaml). containerd + `/etc/containerd/config.toml` must exist on every node — the playbook fails fast if not.
- The same SSH key + `vm` user as the cluster install. The `inventory/` here is a copy of the one in `k8s-setup-w-cilium/`; if you change IPs in one, change both.
- Ansible on the workstation running `run.sh`.

## Versions

Pinned inline in [playbooks/install-registry.yaml](playbooks/install-registry.yaml):

- nerdctl **2.2.2**
- registry image **registry:3.1.1**

To bump, edit the `nerdctl_version` and `registry_image` vars at the top of the install playbook, and the matching `registry:3.1.1` reference in the teardown playbook so cleanup deletes the right image.

## Usage

```shell
cd registry-installation

# Dry-run / syntax checks
bash run.sh playbooks/install-registry.yaml --syntax-check
bash run.sh playbooks/install-registry.yaml --check

# Install: nerdctl on cp, registry container, mirror config on every node
bash run.sh playbooks/install-registry.yaml

# Tear down: reverse all of the above
bash run.sh playbooks/teardown-registry.yaml

# Tear down but keep the nerdctl binary installed
bash run.sh playbooks/teardown-registry.yaml -e remove_nerdctl=false
```

`run.sh` flags: `--check` (dry-run), `--syntax-check`, `--debug=true` (-vvvv). All output is teed to `logs/run-<playbook>-<ts>.log` plus a structured Ansible log alongside.

## What the install playbook does

**Play 1 — control plane only:**

1. Downloads `nerdctl-<ver>-linux-amd64.tar.gz` from `github.com/containerd/nerdctl/releases` and extracts only the `nerdctl` binary into `/usr/local/bin/`. Skipped if the right version is already on PATH.
2. `nerdctl pull registry:3.1.1`.
3. `nerdctl run -d --name registry --restart=always --net=host -v /var/lib/registry:/var/lib/registry registry:3.1.1`. Idempotent: only `run`s if no `registry` container exists, only `start`s if it exists but is stopped.
4. Probes `http://127.0.0.1:5000/v2/` until it returns 200.

**Play 2 — every node in `k8s_cluster`:**

1. Creates `/etc/containerd/certs.d/<cp-ip>:5000/` and writes a `hosts.toml` declaring the registry as `http://<cp-ip>:5000` with `skip_verify = true` and `capabilities = ["pull", "resolve", "push"]`.
2. Edits `/etc/containerd/config.toml` in place: flips `config_path = ""` to `config_path = "/etc/containerd/certs.d"` under `[plugins."io.containerd.grpc.v1.cri".registry]`. **Nothing else in `config.toml` is touched** — `SystemdCgroup = true` set by `install-cluster.yaml` is preserved.
3. `systemctl restart containerd` (via handler).
4. Probes `http://<cp-ip>:5000/v2/` from each node and reports OK/FAIL per host.

## Design notes

**Why `--net=host` for the registry?** nerdctl's default bridge network drops a `nerdctl-bridge.conflist` into `/etc/cni/net.d/`, which on a kubeadm + Cilium node sits next to `05-cilium.conflist` and can break pod networking. Host networking sidesteps the CNI machinery entirely — the registry just listens on `:5000` directly on the control plane.

**Why `certs.d/<host>/hosts.toml` instead of rewriting `config.toml`?** This is the modern containerd pattern (>=1.5). It only requires flipping a single string (`config_path`) inside `config.toml`; the per-registry settings live in their own files. The previous version of this playbook regenerated `config.toml` from `containerd config default`, which silently wiped the `SystemdCgroup = true` setting from the cluster install and could cause kubelet/containerd cgroup-driver mismatches.

**Why a host-network container instead of a static pod / Deployment?** The registry must be reachable *before* the cluster fully trusts it, and on the same machine that controls scheduling. Running it as a plain containerd-managed container outside Kubernetes avoids a chicken-and-egg dependency on the registry being pullable through the kubelet.

**Insecure HTTP only.** This setup is intended for lab / homelab use on the `192.168.48.0/24` subnet. There is no TLS and no authentication. Do not expose port 5000 outside the cluster network.

## FAQ

### Do public registries still work after installing the local registry?

**Yes.** The `certs.d/<host:port>/hosts.toml` layout is **per-host**: containerd only consults that file when the image reference resolves to that exact `host:port`. Everything else uses the default TLS path with full cert verification.

| Image reference | What containerd does |
|---|---|
| `192.168.48.31:5000/myapp:1.0` | reads `/etc/containerd/certs.d/192.168.48.31:5000/hosts.toml`, pulls over plain HTTP, `skip_verify` |
| `nginx:1.27` | resolves to `docker.io`, normal HTTPS pull |
| `registry.k8s.io/pause:3.10` | normal HTTPS pull |
| `ghcr.io/foo/bar:tag` | normal HTTPS pull |

There is no `_default` directory under `certs.d/`, so nothing intercepts the public registries. You'd only break public pulls if you (a) created `/etc/containerd/certs.d/_default/hosts.toml` pointing at the local registry, or (b) used the legacy `registry.mirrors."docker.io"` block to mirror Docker Hub through your local registry. This playbook does neither.

### Why does `nerdctl pull` fail with `rootless containerd not running?`

```
FATA[0000] rootless containerd not running? (hint: use `containerd-rootless-setuptool.sh install` to start rootless containerd): stat /run/user/1000/containerd-rootless: no such file or directory
```

When `nerdctl` is invoked as a non-root user it defaults to talking to a per-user **rootless** containerd at `/run/user/$UID/containerd-rootless`. We don't run rootless containerd on these nodes — the system containerd installed by `install-cluster.yaml` runs as root and its socket at `/run/containerd/containerd.sock` is only readable by root.

Run `nerdctl` under `sudo` instead:

```shell
sudo nerdctl pull alpine:3.20
sudo nerdctl ps
sudo nerdctl images
```

The install playbook itself doesn't hit this because every nerdctl task runs under `become: true` (= root). It only bites during interactive use.

## Verifying the registry

From the workstation (with `kubectl` pointed at the cluster) or from any node:

```shell
CP_IP=$(awk '/^[a-zA-Z0-9_-]+ ansible_host/ {print $2}' inventory/nodes.ini | head -1 | cut -d= -f2)

# Registry HTTP API
curl -s "http://${CP_IP}:5000/v2/" && echo OK
curl -s "http://${CP_IP}:5000/v2/_catalog"

# Push a test image (on the control plane, where nerdctl is installed).
# nerdctl must run as root to reach the system containerd socket — see FAQ below.
ssh vm@${CP_IP} '
  sudo nerdctl pull alpine:3.20
  sudo nerdctl tag alpine:3.20 '"${CP_IP}"':5000/alpine:3.20
  sudo nerdctl push '"${CP_IP}"':5000/alpine:3.20
'

# Pull through containerd (on any node) using crictl
ssh vm@<any-node> "sudo crictl pull ${CP_IP}:5000/alpine:3.20"

# End-to-end: kubelet pulls and runs from the local registry
kubectl run alpine-test -it --rm --image=${CP_IP}:5000/alpine:3.20 -- /bin/sh
```

If `crictl pull` fails with `http: server gave HTTP response to HTTPS client`, the `hosts.toml` didn't take effect — re-run the install playbook (or check that `config_path` in `/etc/containerd/config.toml` actually changed and containerd was restarted).

## Teardown order

[playbooks/teardown-registry.yaml](playbooks/teardown-registry.yaml) reverses the install in this order to keep containerd healthy throughout:

1. **All nodes:** reset `config_path` back to `""`, remove the `certs.d/<cp-ip>:5000/` directory, restart containerd.
2. **Control plane:** `nerdctl stop registry` → `nerdctl rm registry` → `nerdctl rmi registry:3.1.1`.
3. **Control plane:** delete `/var/lib/registry` (the registry's blob store — destructive).
4. **Control plane:** delete `/usr/local/bin/nerdctl` unless `-e remove_nerdctl=false`.

The teardown gracefully no-ops on hosts where the install never ran (nerdctl missing → container/image steps are skipped; missing `config.toml` → containerd reset is skipped).

## Logs

`run.sh` tees every invocation to `logs/` (gitignored), same convention as `k8s-setup-w-cilium/`:

- `logs/run-<playbook>-<ts>.log` — full terminal output
- `logs/ansible-<playbook>-<ts>.log` — structured Ansible log via `ANSIBLE_LOG_PATH`
