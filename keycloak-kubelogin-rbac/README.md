# keycloak-kubelogin-rbac

End-to-end teaching lab that wires together **OpenLDAP → Keycloak → kubelogin → Kubernetes RBAC** on the existing Cilium cluster built by [../k8s-setup-w-cilium/](../k8s-setup-w-cilium/).

The student goal: run `kubectl get pods` from a workstation, get redirected to a browser, log in with an LDAP user (`alice` / `alicepass`), and have RBAC honour the LDAP group membership baked into the JWT issued by Keycloak.

```
   ┌──────────────┐                    ┌──────────────┐                    ┌────────────────┐
   │  OpenLDAP    │ ◄── federation ──► │   Keycloak   │ ◄── OIDC ──────►   │  Cilium k8s    │
   │  (users,     │                    │  (issues ID  │                    │  API server    │
   │   groups)    │                    │   tokens)    │                    │  + RBAC        │
   └──────────────┘                    └──────────────┘                    └────────────────┘
                                              ▲
                                              │ Authorization Code + PKCE
                                              │
                                       ┌──────┴───────┐
                                       │  kubectl +   │
                                       │  kubelogin   │
                                       └──────────────┘
```

This is an adaptation of an upstream kind-based example for a real, multi-node bare-metal cluster. The most visible adaptations:

| Source (kind) | This lab (Cilium cluster) |
|---|---|
| `localtest.me` (resolves to 127.0.0.1) | `keycloak.k8s.lab` resolved via `/etc/hosts` to a MetalLB IP |
| kind kubeadm patches in `cluster.yaml` | Direct edit of `/etc/kubernetes/manifests/kube-apiserver.yaml` over SSH |
| CoreDNS rewrite for issuer DNS | `hostAliases` on the kube-apiserver static pod |
| Single-container kind cluster | Existing 4-node cluster (1 CP at .31, 3 workers at .32-.34) |
| kind ingress provider manifest | bare-metal `provider/cloud/deploy.yaml` of ingress-nginx + MetalLB |

## Prerequisites

- A running Cilium cluster (e.g. built by [../k8s-setup-w-cilium/playbooks/install-cluster.yaml](../k8s-setup-w-cilium/playbooks/install-cluster.yaml)).
- A merged kubeconfig on the workstation. Use [../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh](../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh) and verify with `kubectl config current-context` (default: `cilium-lab`).
- **MetalLB** installed via [../metallb-installation/setup-metallb.sh](../metallb-installation/setup-metallb.sh). When this lab installs ingress-nginx fresh, it pins the controller to **192.168.48.202** by default (override with `INGRESS_LB_IP=...`). If ingress-nginx is **already installed** by another lab (e.g. [../ingress-nginx-w-certificate/](../ingress-nginx-w-certificate/) which uses `192.168.48.201`), this lab adopts that controller's existing EXTERNAL-IP instead of re-pinning, so the two labs coexist without a tug-of-war over the shared `ingress-nginx-controller` Service.
- **A default StorageClass** in the cluster — both OpenLDAP and Keycloak's Postgres are StatefulSets with `volumeClaimTemplates` and no explicit `storageClassName`. The base [../k8s-setup-w-cilium/](../k8s-setup-w-cilium/) install ships none, so PVCs stay Pending forever. Quick fix on this cluster:
  ```shell
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
  kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=true --overwrite
  ```
  Data lives under `/opt/local-path-provisioner/` on whichever node the pod schedules. Use a real backend (Longhorn, NFS, OpenEBS) if you care about node-loss survival.
- **SSH access** to the control-plane node `vm@192.168.48.31` using [../k8s-setup-w-cilium/inventory/node-ssh-key](../k8s-setup-w-cilium/inventory/node-ssh-key). Step 05 edits the kube-apiserver static pod manifest there.
- **`kubelogin`** on the workstation — specifically [int128/kubelogin](https://github.com/int128/kubelogin), NOT Microsoft's Azure kubelogin (same binary name, different tool — `snap install kubelogin` typically pulls the Azure one). The lab disambiguates by checking `kubelogin --help` for the string `azure active directory` and falling back to the krew plugin if found. Install with one of:
  - `kubectl krew install oidc-login` (recommended)
  - `brew install int128/kubelogin/kubelogin` (macOS)
  - `go install github.com/int128/kubelogin/cmd/kubelogin@latest`
- **`sudo`** on the workstation: step 04 writes a managed block to `/etc/hosts`.
- ~2 GB free RAM in the cluster for OpenLDAP + Keycloak + Postgres.

## Two student paths

### Lazy path (one command)

```shell
bash setup-keycloak-rbac.sh
```

Then:

```shell
kubectl --context cilium-lab-oidc get pods -A
# browser pops, log in as alice / alicepass
```

Tear down with `bash teardown-keycloak-rbac.sh`.

### Logging in from a different workstation than where setup ran

`kubelogin` and the **browser** must run on the **same machine** — kubelogin starts an HTTP listener on `localhost:8000` (or `:18000`) and the OAuth flow redirects back to that port. If kubectl runs on the control-plane node over SSH and the browser is on your laptop, the redirect lands on the laptop's `localhost:8000` (nothing listening) and login fails. So the OIDC context normally lives on a workstation with a GUI, not on the cluster nodes.

To move the OIDC context onto a Mac (or any other workstation):

1. **Pull the kubeconfig and lab CA from the cluster.** The CA path that step 06 baked into the kubeconfig is `${HOME}/.keycloak-lab/ca.crt` *on the control-plane node* — the next step rewrites it for your local home dir.
   ```bash
   scp vm@192.168.48.31:~/.kube/config ~/.kube/cilium-lab-oidc.conf
   mkdir -p ~/.keycloak-lab
   scp vm@192.168.48.31:.keycloak-lab/ca.crt ~/.keycloak-lab/ca.crt
   ```
2. **Rewrite the CA path inside the kubeconfig** so it points at *your* `~/.keycloak-lab/ca.crt`.
   ```bash
   # macOS:
   sed -i '' "s|/home/vm/.keycloak-lab/ca.crt|$HOME/.keycloak-lab/ca.crt|g" ~/.kube/cilium-lab-oidc.conf
   # Linux:
   sed -i    "s|/home/vm/.keycloak-lab/ca.crt|$HOME/.keycloak-lab/ca.crt|g" ~/.kube/cilium-lab-oidc.conf
   ```
3. **Add `keycloak.k8s.lab` → ingress IP to `/etc/hosts` on this workstation.** The IP must match whatever the cluster's `ingress-nginx-controller` Service has assigned (default for this lab is `192.168.48.202`, often `192.168.48.204` if MetalLB rotated). Get it with `kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`.
   ```bash
   echo "192.168.48.204  keycloak.k8s.lab" | sudo tee -a /etc/hosts
   ```
4. **Install int128/kubelogin** (see [Prerequisites](#prerequisites) — Microsoft's Azure kubelogin is a different tool with the same name).
   ```bash
   brew install int128/kubelogin/kubelogin     # macOS
   # OR
   kubectl krew install oidc-login             # cross-platform via krew
   ```

Then:

```bash
export KUBECONFIG=~/.kube/cilium-lab-oidc.conf
kubectl --context cilium-lab-oidc get pods -A
```

A browser opens to `https://keycloak.k8s.lab/...`. The lab CA is self-signed, so you'll see a "Your connection is not private" warning — click through (or import `~/.keycloak-lab/ca.crt` into the OS trust store to silence it). Log in as `alice / alicepass` to get cluster-admin, `bob / bobpass` for read-only, or `carol / carolpass` to authenticate with no permissions.

> **Headless alternative.** If you can't run a browser at all (CI, headless server), pass `--grant-type=password` to kubelogin via the kubeconfig exec args — kubelogin will prompt for username/password on stdin. This requires enabling `directAccessGrantsEnabled` on the `kubernetes` client in the realm import (currently `false`). Re-import the realm after the change.

### Step-by-step path

Run each script in order to read what each one does. They are independent and idempotent:

```shell
bash step-by-step/00-prereq-check.sh
bash step-by-step/01-install-ingress-nginx.sh
bash step-by-step/02-deploy-openldap.sh
bash step-by-step/03-deploy-keycloak.sh
bash step-by-step/04-add-hosts-entries.sh
bash step-by-step/05-enable-oidc-on-apiserver.sh
bash step-by-step/06-configure-kubeconfig.sh
bash step-by-step/07-apply-rbac.sh
bash step-by-step/08-test-login.sh   # interactive persona walkthrough
```

## Layout

```
keycloak-kubelogin-rbac/
├── README.md                            ← this file
├── setup-keycloak-rbac.sh               ← lazy: runs all step-by-step/* in order
├── teardown-keycloak-rbac.sh            ← lazy: reverses everything
├── create-keycloak-tls.sh               ← self-signed CA + server cert for keycloak.k8s.lab (called from step 03)
├── step-by-step/
│   ├── 00-prereq-check.sh               ← read-only checks
│   ├── 01-install-ingress-nginx.sh      ← installs ingress-nginx (pins to 192.168.48.202 if fresh; adopts existing IP otherwise)
│   ├── 02-deploy-openldap.sh            ← OpenLDAP + LDIF (alice, bob, carol)
│   ├── 03-deploy-keycloak.sh            ← cert + Postgres + Keycloak + realm import
│   ├── 04-add-hosts-entries.sh          ← /etc/hosts on workstation
│   ├── 05-enable-oidc-on-apiserver.sh   ← SCPs lab CA, edits kube-apiserver static pod over SSH
│   ├── 06-configure-kubeconfig.sh       ← adds OIDC user + context (kubelogin trusts lab CA)
│   ├── 07-apply-rbac.sh                 ← ClusterRoleBindings on the OIDC groups
│   └── 08-test-login.sh                 ← interactive 3-persona smoke test
└── manifests/
    ├── 00-namespace.yaml
    ├── 20-openldap.yaml                 ← bitnami/openldap + bootstrap LDIF
    ├── 30-keycloak-db.yaml              ← Postgres for Keycloak
    ├── 31-keycloak.yaml                 ← Keycloak Deployment + Service + Ingress
    ├── 40-keycloak-realm-import.yaml    ← ConfigMap with realm JSON
    └── 50-rbac.yaml                     ← group-based ClusterRoleBindings
```

## What runs where

| Component | Namespace | Service / Hostname | Purpose |
|---|---|---|---|
| OpenLDAP | `identity` | `openldap.identity.svc.cluster.local:389` | Directory backend |
| Keycloak Postgres | `identity` | `keycloak-db.identity.svc.cluster.local:5432` | Keycloak's DB |
| Keycloak | `identity` | `https://keycloak.k8s.lab` (TLS terminated at the ingress, self-signed lab CA) | OIDC issuer (browser + API server) |
| ingress-nginx | `ingress-nginx` | `EXTERNAL-IP 192.168.48.202` (or whatever the existing controller already has) | Routes the hostname above |
| OIDC validation | `kube-system` | kube-apiserver static pod | `--oidc-*` flags + hostAliases |

## Personas

| User | LDAP password | LDAP groups | Mapped to | Expected behaviour |
|---|---|---|---|---|
| `alice` | `alicepass` | `k8s-admins` | `cluster-admin` (via `oidc:k8s-admins`) | Full read/write everywhere |
| `bob`   | `bobpass`   | `k8s-viewers` | `view` (via `oidc:k8s-viewers`) | Can list pods, **cannot** read Secrets, **cannot** mutate |
| `carol` | `carolpass` | _(none)_ | _(no binding)_ | Authenticates, but every API call returns `Forbidden` |

`step-by-step/08-test-login.sh` walks through all three back-to-back, using a separate token cache per persona so you don't need to clear cookies between runs.

## Configuration

All scripts read defaults from environment variables. The interesting ones:

| Variable | Default | Used by |
|---|---|---|
| `INGRESS_LB_IP` | env override → existing `ingress-nginx-controller` EXTERNAL-IP → `192.168.48.202` | 00, 01, 04, 05 — when ingress-nginx is already installed (e.g. by `../ingress-nginx-w-certificate/`), the existing IP is adopted automatically |
| `KEYCLOAK_HOST` | `keycloak.k8s.lab` | 04, 05, 06 |
| `ISSUER` | `https://${KEYCLOAK_HOST}/realms/k8s` | 05, 06 — must be byte-identical between API server and kubeconfig (K8s ≥ 1.30 requires `https://`) |
| `CERT_DIR` | `${HOME}/.keycloak-lab` | `create-keycloak-tls.sh`, 03, 05, 06 — cache for the lab CA + server cert |
| `LAB_CA_CRT` | `${CERT_DIR}/ca.crt` | 06 — passed to kubelogin as `--certificate-authority` |
| `REMOTE_CA_CRT` | `/etc/kubernetes/pki/keycloak-ca.crt` | 05, teardown — where step 05 SCPs the CA on the control plane |
| `FORCE_REGEN` | `0` | `create-keycloak-tls.sh` — set to `1` to rotate the lab CA |
| `REMOVE_LAB_CERTS` | `1` | teardown — set to `0` to keep `${CERT_DIR}` across teardown/install cycles |
| `CONTROL_PLANE_HOST` | `192.168.48.31` | 00, 05, teardown |
| `CONTROL_PLANE_USER` | `vm` | 00, 05, teardown |
| `SSH_KEY` | `../k8s-setup-w-cilium/inventory/node-ssh-key` | 00, 05, teardown |
| `ADMIN_CTX` | `cilium-lab` | 06, 07, teardown |
| `OIDC_CTX` | `cilium-lab-oidc` | 06, 08, teardown |
| `INGRESS_NGINX_VERSION` | `controller-v1.15.1` | 01, teardown |

**Caveat:** `kubernetes/ingress-nginx` was archived 2026-03-24; `controller-v1.15.1` is the final release. Same constraint as [../ingress-nginx-w-certificate/](../ingress-nginx-w-certificate/).

## How the auth flow actually works

1. `kubectl get pods` reads kubeconfig — user `cilium-lab-oidc-user` has an exec credential plugin → kubelogin runs.
2. kubelogin checks `~/.kube/cache/oidc-login/<hash>`. If valid, returns it.
3. Otherwise it fetches `https://keycloak.k8s.lab/realms/k8s/.well-known/openid-configuration` (kubelogin uses `--certificate-authority=${HOME}/.keycloak-lab/ca.crt` to trust the self-signed lab CA).
4. A browser opens at `http://localhost:8000`; redirects to Keycloak login.
5. You enter `alice / alicepass`. Keycloak's LDAP federation does an LDAP simple bind against `openldap.identity.svc.cluster.local:389` to verify the password.
6. Keycloak builds an ID token (JWT, RS256) with `iss=https://keycloak.k8s.lab/realms/k8s`, `aud=kubernetes`, `preferred_username=alice`, `groups=["k8s-admins"]`.
7. kubelogin prints the token to kubectl; kubectl puts it in `Authorization: Bearer ...` on the API call.
8. The API server validates the JWT (signature via Keycloak JWKS, `iss`, `aud`, `exp`), then extracts:
   - `username = oidc:alice`
   - `groups = [oidc:k8s-admins, system:authenticated]`
9. RBAC sees `Group oidc:k8s-admins` bound to `cluster-admin` → allow.

## Why each pin matters

- **`oidc:` prefix** on `--oidc-username-prefix` and `--oidc-groups-prefix` is a security control. Without it, a Keycloak group named `system:masters` would automatically inherit cluster-admin via the built-in binding. The prefix puts every OIDC identity in a namespace that can't collide with `system:*`.
- **`hostAliases` on the kube-apiserver static pod**: the API server's pod has its own kubelet-managed `/etc/hosts` (not the host's), so editing `/etc/hosts` on the control-plane node would *not* let the API server resolve `keycloak.k8s.lab`. `hostAliases` is the supported way to inject a name → IP mapping that survives pod restarts.
- **MetalLB-pinned ingress IP**: the `/etc/hosts` entries on every workstation point at a specific IP. If the ingress controller's EXTERNAL-IP drifted (because MetalLB rotated allocations), every student's `/etc/hosts` would silently point at the wrong host. When this lab installs ingress-nginx fresh, the annotation `metallb.universe.tf/loadBalancerIPs=192.168.48.202` keeps it stable. When ingress-nginx is already installed (e.g. by [../ingress-nginx-w-certificate/](../ingress-nginx-w-certificate/) which pins `192.168.48.201`), this lab leaves the annotation alone and adopts that IP for `/etc/hosts` and `hostAliases`.
- **`KC_HOSTNAME=https://keycloak.k8s.lab` byte-identical to `--oidc-issuer-url`**: the API server compares the JWT `iss` claim against the flag exactly. A trailing slash, an extra port, or `http`-vs-`https` is enough to break it with `oidc: issuer did not match`.
- **HTTPS, not HTTP, on the issuer**: Kubernetes ≥ 1.30 rejects `http://` in `--oidc-issuer-url` with `URL scheme must be https`. The lab generates a self-signed CA + server cert via `create-keycloak-tls.sh`; the server cert lives in Secret `keycloak-tls` (referenced by the Ingress' `tls:` block), and the CA is SCP'd to `/etc/kubernetes/pki/keycloak-ca.crt` on the control plane and consumed via `--oidc-ca-file`. kubelogin trusts the same CA via `--certificate-authority`. Browsers will warn about the self-signed cert — that's expected; click through.
- **CA path lives under `/etc/kubernetes/pki/`**: kubeadm already mounts that directory into the kube-apiserver static pod at the same path, so dropping `keycloak-ca.crt` next to `ca.crt` makes it visible to the apiserver container without editing the static pod's volumeMounts.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `kubectl get pods` → `error: You must be logged in to the server (Unauthorized)` after browser flow succeeds | API server cannot reach Keycloak (DNS), or `iss` claim mismatch | Confirm hostAliases on kube-apiserver: `kubectl get pod -n kube-system -l component=kube-apiserver -o yaml \| grep -A3 hostAliases`. Then check the JWT `iss` field by decoding the token. |
| Browser opens, "Invalid username or password" | LDAP federation cannot validate password | `kubectl exec -n identity openldap-0 -- ldapsearch -x -D 'uid=alice,...' -w alicepass -b 'uid=alice,...'` — if it fails, delete the LDAP PVC + pod and let the LDIF re-run |
| `keycloak.k8s.lab` does not resolve from workstation | `/etc/hosts` block missing | Re-run `step-by-step/04-add-hosts-entries.sh` |
| ingress-nginx Service stays `<pending>` | MetalLB not installed, or `192.168.48.202` already used | `kubectl get svc -A -o wide \| grep 192.168.48.202` and free the IP |
| Realm import didn't run (no `kubernetes` client visible in admin UI) | Keycloak DB already has the realm from a previous run | `kubectl delete pvc -n identity -l app.kubernetes.io/name=keycloak-db && kubectl rollout restart -n identity deploy/keycloak` |
| OIDC flags on disk but not on the running kube-apiserver pod | `*.bak-*` files in `/etc/kubernetes/manifests/` — kubelet treats them as additional pod manifests with the same name | Move backups out: `sudo mv /etc/kubernetes/manifests/*.bak-* /etc/kubernetes/kube-apiserver-backups/` (the current scripts already write backups there; this only matters for clusters that ran older versions of these scripts) |
| `kube-apiserver` crashloops with `URL scheme must be https` | Issuer URL is `http://` somewhere | Confirm `--oidc-issuer-url=https://...` on the apiserver and `KC_HOSTNAME=https://...` on Keycloak. K8s ≥ 1.30 enforces this. |
| `kube-apiserver` crashloops with `failed to get keys: x509: certificate signed by unknown authority` | `--oidc-ca-file` missing or pointing at a file the apiserver can't read | `ssh control-plane sudo ls -l /etc/kubernetes/pki/keycloak-ca.crt` — should be present, mode 0644. Re-run step 05 if missing. |
| `kubelogin` complains about cert verification | `--certificate-authority` not set, or CA file rotated | Re-run step 06 (or pass `--insecure-skip-tls-verify` to kubelogin if you really must) |
| Browser shows "Your connection is not private" | Self-signed lab cert — expected | Click through (Advanced → Proceed). To avoid the warning entirely, import `${HOME}/.keycloak-lab/ca.crt` into your OS / browser trust store. |

## Tear down

```shell
bash teardown-keycloak-rbac.sh
```

By default this leaves MetalLB and ingress-nginx in place (they may be shared with other labs in this repo). Pass `REMOVE_INGRESS_NGINX=1` to delete ingress-nginx as well, or `SKIP_APISERVER_REVERT=1` to leave OIDC enabled on the API server.

## Versions

Pinned inline:

- bitnamilegacy/openldap **2.6.10** — [manifests/20-openldap.yaml](manifests/20-openldap.yaml) (Bitnami's `bitnami/*` Docker Hub repos were deprecated 2025-08-28; older tags now live in the public `bitnamilegacy/*` namespace)
- postgres **16-alpine** — [manifests/30-keycloak-db.yaml](manifests/30-keycloak-db.yaml)
- quay.io/keycloak/keycloak **26.6** — [manifests/31-keycloak.yaml](manifests/31-keycloak.yaml)
- ingress-nginx controller **v1.15.1** (final release; project archived 2026-03-24) — [step-by-step/01-install-ingress-nginx.sh](step-by-step/01-install-ingress-nginx.sh)

To bump any version, edit the file above; teardown follows the same versions because it deletes by manifest path.
