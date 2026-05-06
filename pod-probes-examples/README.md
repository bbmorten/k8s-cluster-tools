# pod-probes-examples

Hands-on lab for Kubernetes **pod probes**: `livenessProbe`, `readinessProbe`, and `startupProbe`. Each manifest in [manifests/](manifests/) demonstrates one probe shape so you can watch the kubelet make a decision in real time — restart a deadlocked container, hold traffic until a pod is ready, or wait for a slow-starting app before applying aggressive liveness checks.

Same shape as [../metallb-installation/](../metallb-installation/): two shell scripts that talk to the cluster through the caller's current `kubectl` context. No Ansible, no inventory, nothing installed on the nodes.

Reference docs:

- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Liveness, Readiness, and Startup Probes (concept)](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)

## Layout

```
pod-probes-examples/
├── README.md
├── setup-pod-probes.sh         # apply 00..60 manifests in order
├── teardown-pod-probes.sh      # delete everything + namespace
└── manifests/
    ├── 00-namespace.yaml
    ├── 10-liveness-exec.yaml
    ├── 20-liveness-http.yaml
    ├── 30-liveness-tcp.yaml
    ├── 40-readiness-exec.yaml
    ├── 50-startup-and-liveness.yaml
    └── 60-combined-deployment.yaml
```

## Prerequisites

- A running cluster (e.g. built by [../k8s-setup-w-cilium/playbooks/install-cluster.yaml](../k8s-setup-w-cilium/playbooks/install-cluster.yaml)).
- A merged kubeconfig on the workstation. Use [../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh](../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh) and verify with `kubectl config current-context` before running these scripts.
- Outbound access to `registry.k8s.io` for the `busybox` and `agnhost` images.
- No MetalLB needed — every Service in this lab is `ClusterIP`.

## Versions

Pinned inline in the manifests:

- `registry.k8s.io/busybox:1.27.2` — used by 10/40/50.
- `registry.k8s.io/e2e-test-images/agnhost:2.40` — used by 20/30/60.

To bump, grep for `image:` under [manifests/](manifests/) and update each occurrence.

## Lazy path (just run it)

```shell
# Point kubectl at the cluster first
bash ../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh
kubectl config current-context   # should be cilium-lab

bash setup-pod-probes.sh         # apply every example
bash teardown-pod-probes.sh      # remove everything
```

The setup script applies every manifest into the `pod-probes-demo` namespace, waits for the combined Deployment to roll out, and prints suggested commands for observing each probe in action. Re-running is safe — every step is `kubectl apply` and the teardown uses `--ignore-not-found`.

## Probe primer

Three probe types, all configured the same way (one of `exec` / `httpGet` / `tcpSocket` / `grpc`):

| Probe | Question it answers | Action on failure |
|---|---|---|
| `livenessProbe` | Is the container still working? | kubelet **restarts** the container |
| `readinessProbe` | Should this container receive traffic? | kubelet removes the Pod IP from the **EndpointSlice** (no restart) |
| `startupProbe` | Has the app finished booting? | kubelet **restarts** the container; **disables** liveness & readiness until success |

All three share these tunables (defaults in parens):

| Field | Default | Purpose |
|---|---|---|
| `initialDelaySeconds` | 0 | Delay before the first probe |
| `periodSeconds` | 10 | Interval between probes |
| `timeoutSeconds` | 1 | Probe timeout |
| `successThreshold` | 1 | Consecutive successes to mark healthy after a failure |
| `failureThreshold` | 3 | Consecutive failures before action |
| `terminationGracePeriodSeconds` | inherits pod | Grace period on probe-triggered kill |

Outcome states: **Success**, **Failure**, **Unknown** (kubelet takes no action on Unknown).

> **Liveness pitfall.** Aggressive liveness probes against a load-sensitive app cause cascading restarts under load. Use liveness only to detect *unrecoverable* states; otherwise prefer readiness or rely on the app's own crash behaviour.

---

## Step-by-step examples

Every command below assumes you are in the `pod-probes-examples/` directory and `kubectl` is pointed at the lab cluster. If you ran `setup-pod-probes.sh`, the resources already exist — you can skip the `apply` and jump to the observation commands.

The shared namespace:

```shell
kubectl apply -f manifests/00-namespace.yaml
```

### Example 1 — Liveness probe (exec)

[manifests/10-liveness-exec.yaml](manifests/10-liveness-exec.yaml) launches busybox with this command sequence:

```
touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600
```

The probe runs `cat /tmp/healthy` every 5s starting 5s after launch. The file disappears at t=30s, so probes start failing at t=30s and the kubelet restarts the container after `failureThreshold: 3` failures (≈t=45s).

```shell
kubectl apply -f manifests/10-liveness-exec.yaml

# Watch the RESTARTS column climb every ~50s:
kubectl -n pod-probes-demo get pod liveness-exec -w

# See the kubelet's reason for the restart:
kubectl -n pod-probes-demo describe pod liveness-exec | grep -A2 -i liveness

# Look at the previous container's logs after a restart:
kubectl -n pod-probes-demo logs liveness-exec --previous
```

Key teaching point: **liveness failure restarts the container, not the pod**. The Pod's UID and IP stay the same; only the container is recreated.

### Example 2 — Liveness probe (HTTP)

[manifests/20-liveness-http.yaml](manifests/20-liveness-http.yaml) uses the `agnhost liveness` test app, which serves `/healthz` returning `200` for the first ~10s after each start, then `500`. HTTP codes 200–399 are success; anything else is failure.

```shell
kubectl apply -f manifests/20-liveness-http.yaml

kubectl -n pod-probes-demo get pod liveness-http -w
kubectl -n pod-probes-demo describe pod liveness-http | grep -A4 Liveness
```

Note the `Custom-Header: Awesome` field — `httpGet.httpHeaders` is how you attach auth tokens or routing hints when the health endpoint demands them.

### Example 3 — TCP socket probe

[manifests/30-liveness-tcp.yaml](manifests/30-liveness-tcp.yaml) starts `agnhost netexec` listening on port 8080 and uses **both** a readiness and a liveness `tcpSocket` probe. A TCP probe succeeds if the kubelet can `connect()` to the port.

```shell
kubectl apply -f manifests/30-liveness-tcp.yaml

kubectl -n pod-probes-demo get pod tcp-probe
kubectl -n pod-probes-demo describe pod tcp-probe | grep -A2 -E 'Liveness|Readiness'
```

The pod stays Ready and is not restarted as long as port 8080 is open. Useful for databases or queues that don't expose an HTTP health endpoint.

### Example 4 — Readiness probe (exec)

[manifests/40-readiness-exec.yaml](manifests/40-readiness-exec.yaml) sleeps 20s before creating `/tmp/ready`. The probe runs `cat /tmp/ready` every 5s. Until the file exists, the pod is **Running but not Ready** — and the `readiness-demo` Service does not route traffic to it.

```shell
kubectl apply -f manifests/40-readiness-exec.yaml

# Two terminals are useful here:
# Terminal A — watch the pod's READY column flip from 0/1 to 1/1 around t=25s:
kubectl -n pod-probes-demo get pod readiness-exec -w

# Terminal B — watch the EndpointSlice populate when the pod becomes Ready:
kubectl -n pod-probes-demo get endpointslices \
  -l kubernetes.io/service-name=readiness-demo -w

# Now break readiness on the live pod and watch it leave the EndpointSlice:
kubectl -n pod-probes-demo exec readiness-exec -- rm /tmp/ready

# Restore it:
kubectl -n pod-probes-demo exec readiness-exec -- touch /tmp/ready
```

Key teaching point: **readiness failure does not restart the container**. It only removes the pod from Service endpoints, so traffic stops while the container itself keeps running.

### Example 5 — Startup probe gating an aggressive liveness probe

[manifests/50-startup-and-liveness.yaml](manifests/50-startup-and-liveness.yaml) simulates a slow-starting app: it sleeps 30s before creating `/tmp/started` and `/tmp/healthy`. The liveness probe has `failureThreshold: 1` (one failure → restart) — without a startup probe it would kill the container almost immediately.

The startup probe (`failureThreshold: 30, periodSeconds: 5`) gives the app up to ~150s to come up and **suppresses liveness/readiness while it runs**. Once `/tmp/started` exists, the kubelet hands over to liveness.

```shell
kubectl apply -f manifests/50-startup-and-liveness.yaml

kubectl -n pod-probes-demo get pod startup-demo -w
kubectl -n pod-probes-demo describe pod startup-demo | grep -A2 -E 'Startup|Liveness'
```

Expected: no restarts during the 30s startup window; `RESTARTS=0` permanently after that. To prove the gating, edit the manifest to remove the startup probe and re-apply — the pod will restart immediately.

### Example 6 — All three probes on a real Deployment

[manifests/60-combined-deployment.yaml](manifests/60-combined-deployment.yaml) is the production-shaped example: 2 replicas of `agnhost netexec` behind a ClusterIP Service, with the recommended probe layering — slow-tolerant startup, lenient liveness, sensitive readiness.

```shell
kubectl apply -f manifests/60-combined-deployment.yaml
kubectl -n pod-probes-demo rollout status deploy/combined

kubectl -n pod-probes-demo get pods -l app=combined
kubectl -n pod-probes-demo describe deploy combined | grep -A3 -E 'Startup|Liveness|Readiness'

# Hit the Service from inside the cluster:
kubectl -n pod-probes-demo run curl --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.40 -- \
  curl -s http://combined.pod-probes-demo.svc.cluster.local
```

Probe layering rationale (from the concepts page):

- **Startup**: tolerates long boots without skewing liveness behaviour later.
- **Liveness** (`periodSeconds: 20`, `failureThreshold: 3` → 60s grace): only catches *deadlocks*, not transient blips.
- **Readiness** (`periodSeconds: 5`, `failureThreshold: 1`): pulls the pod out of the EndpointSlice immediately on the first hiccup so clients don't get errors.

## What setup does

[setup-pod-probes.sh](setup-pod-probes.sh) applies the manifests in numeric order:

1. `00-namespace.yaml` — creates `pod-probes-demo`.
2. `10-liveness-exec.yaml` — exec-based liveness probe.
3. `20-liveness-http.yaml` — HTTP liveness probe.
4. `30-liveness-tcp.yaml` — TCP socket readiness + liveness.
5. `40-readiness-exec.yaml` — exec-based readiness probe + headless Service.
6. `50-startup-and-liveness.yaml` — startup probe gating an aggressive liveness probe.
7. `60-combined-deployment.yaml` — Deployment + Service with all three probes.

Then it waits on the combined rollout and prints suggested observation commands.

## What teardown does

[teardown-pod-probes.sh](teardown-pod-probes.sh) deletes the manifests in reverse order, then deletes the namespace and waits for it to terminate. Every `kubectl delete` uses `--ignore-not-found`, so re-running on a partially-installed cluster is safe.

## Troubleshooting

- **`liveness-http` keeps restarting forever** — that's the expected behaviour. `agnhost liveness` is *designed* to flip its `/healthz` to 500 after ~10s; the probe restarts the container, then the cycle repeats. If you want it to stop, delete the pod.
- **Image pull errors** — the cluster needs outbound HTTPS to `registry.k8s.io`. If you use the in-cluster registry from [../registry-installation/](../registry-installation/), the official images still have to be pulled at least once on each node.
- **`startup-demo` is restarting in the first 30s** — confirm the startup probe is actually present: `kubectl get pod startup-demo -o jsonpath='{.spec.containers[0].startupProbe}'`. If empty, you applied an older version of the manifest.
- **`readiness-demo` Service has no endpoints** — readiness probes mark the pod NotReady; check `kubectl describe pod readiness-exec` for `Readiness probe failed`. The most common cause is the file got removed (e.g. via `kubectl exec ... rm /tmp/ready`) — `touch` it again.
- **Namespace stuck `Terminating`** — usually a finalizer on a leftover resource. List with `kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n pod-probes-demo --ignore-not-found 2>/dev/null` and remove finalizers as needed.
