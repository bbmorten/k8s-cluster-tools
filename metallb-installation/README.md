# metallb-installation

Install **MetalLB** in L2 mode against an already-running cluster so that Services of `type: LoadBalancer` actually get an external IP. Cilium's install in [../k8s-setup-w-cilium/](../k8s-setup-w-cilium/) does **not** provide LoadBalancer IP allocation, so without this step those Services stay stuck in `<pending>`.

Unlike the sibling Ansible projects, this folder is just two shell scripts that talk to the cluster through the caller's current `kubectl` context. There is no inventory, no `run.sh`, and nothing is installed on the nodes themselves — everything lives inside the `metallb-system` namespace.

## Layout

```
metallb-installation/
├── setup-metallb.sh      # apply manifest + IPAddressPool + L2Advertisement + stub test svc
└── teardown-metallb.sh   # reverse all of the above in order
```

## Prerequisites

- A running cluster (e.g. built by [../k8s-setup-w-cilium/playbooks/install-cluster.yaml](../k8s-setup-w-cilium/playbooks/install-cluster.yaml)).
- A merged kubeconfig on the workstation. Use [../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh](../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh) and verify with `kubectl config current-context` before running these scripts.
- The IP range `192.168.48.201-192.168.48.205` must be free and routable on the same L2 segment as the nodes (`192.168.48.31-34`). L2 mode requires this — the speaker pods ARP for the VIPs from the nodes themselves, so the VIPs and nodes have to share a broadcast domain.

## Versions

Pinned inline in **both** scripts (keep them in sync):

- MetalLB **v0.15.3** — [setup-metallb.sh:7](setup-metallb.sh#L7) and [teardown-metallb.sh:10](teardown-metallb.sh#L10) (`METALLB_MANIFEST` variable).

To bump the version, edit the URL in both files so teardown deletes exactly what setup applied.

## Usage

```shell
# Point kubectl at the cluster first
bash ../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh
kubectl config current-context   # should be cilium-lab

# Install
bash setup-metallb.sh

# Tear down
bash teardown-metallb.sh
```

## What setup does

[setup-metallb.sh](setup-metallb.sh) runs five steps in order:

1. `kubectl apply -f` the upstream `metallb-native.yaml` manifest at `v0.15.3` — installs the `metallb-system` namespace, controller Deployment, speaker DaemonSet, webhooks, RBAC, and CRDs.
2. `kubectl wait` on `app=metallb` pods (`Ready`, 90 s).
3. Create an `IPAddressPool` named **first-pool** with range `192.168.48.201-192.168.48.205`.
4. Create an `L2Advertisement` named **l2-advertisement** referencing `first-pool`.
5. Create a stub `Service` named **test-service** in `default` of `type: LoadBalancer` whose selector matches no pods. This is just a probe to confirm that the controller hands out an EXTERNAL-IP — `kubectl get svc test-service` should show one of `192.168.48.201-205` within a few seconds.

## Address pool

| Setting | Value |
|---|---|
| Pool name | `first-pool` |
| Range | `192.168.48.201 – 192.168.48.205` (5 IPs) |
| Mode | L2 (`L2Advertisement`, no BGP) |
| Subnet | same `/24` as the nodes (`192.168.48.0/24`) |

To change the range, edit the `addresses:` block in [setup-metallb.sh](setup-metallb.sh#L24-L25) before running, or after install with:

```shell
kubectl edit ipaddresspool first-pool -n metallb-system
```

## Wiring an ingress controller to a LoadBalancer IP

Once MetalLB is up, switch any NodePort Service to `type: LoadBalancer` and it will get an EXTERNAL-IP from the pool. Example for ingress-nginx:

```shell
kubectl patch svc nginx-ingress-ingress-nginx-controller -n ingress-nginx \
  -p '{"spec":{"type":"LoadBalancer"}}'
```

Reverting before teardown:

```shell
kubectl patch svc nginx-ingress-ingress-nginx-controller -n ingress-nginx \
  -p '{"spec":{"type":"NodePort"}}'
```

The teardown script does **not** revert these patches automatically — it only prints a reminder. Any Service still set to `type: LoadBalancer` after teardown will go back to `<pending>`.

## What teardown does

[teardown-metallb.sh](teardown-metallb.sh) reverses the install in this order to avoid orphaning resources behind a deleted webhook:

1. `kubectl delete service test-service -n default` (the stub from step 5).
2. `kubectl delete l2advertisement l2-advertisement -n metallb-system`.
3. `kubectl delete ipaddresspool first-pool -n metallb-system`.
4. `kubectl delete -f <manifest>` — removes the namespace, controller, speaker DaemonSet, webhooks, RBAC, and CRDs.
5. `kubectl wait --for=delete namespace/metallb-system --timeout=120s`.
6. Verify: warns if `metallb-system` namespace or any `metallb.io` CRDs still exist.

Every `kubectl delete` uses `--ignore-not-found`, so re-running on a partially-installed cluster is safe.

## Troubleshooting

- **`test-service` stays `<pending>`** — check `kubectl logs -n metallb-system -l component=controller`. Most common cause is that the IPAddressPool or L2Advertisement didn't apply because the webhook wasn't ready yet; re-run `setup-metallb.sh` (it's idempotent).
- **EXTERNAL-IP assigned but unreachable** — verify the pool range is on the same `/24` as the nodes and not in use elsewhere on the LAN. L2 mode relies on gratuitous ARP from one of the speaker pods; if a router or another host already owns the IP, you'll get intermittent or no connectivity.
- **`namespace metallb-system` stuck `Terminating`** — usually a leftover finalizer on a CR. Delete remaining `IPAddressPool`/`L2Advertisement`/`BGPPeer` objects manually, then re-run teardown.
