# service-types-examples

Hands-on lab covering the five Kubernetes Service flavors students see in the wild:

| # | Type | Reachable from | Picks pod via | Notes |
|---|------|---------------|---------------|-------|
| 1 | **ClusterIP** | inside cluster only | virtual IP + kube-proxy/Cilium | the default |
| 2 | **NodePort** | any node IP : port | virtual IP + nodePort | superset of ClusterIP |
| 3 | **LoadBalancer** | external IP | virtual IP + nodePort + LB | superset of NodePort; needs MetalLB on bare metal |
| 4 | **ExternalName** | inside cluster only (DNS) | CNAME, no proxy | for off-cluster dependencies |
| 5 | **Headless** (`clusterIP: None`) | inside cluster (DNS A per pod) | client picks | no VIP, no kube-proxy rule |

Two ways to use the lab:

- **Manual / read-along** — `kubectl apply -f manifests/<file>` one at a time, read the comments in the YAML, observe what each Service does.
- **Lazy** — `bash setup-service-types.sh` applies them all and prints test commands; `bash teardown-service-types.sh` deletes everything.

This folder follows the same shape as [../metallb-installation/](../metallb-installation/): no Ansible, no inventory, just shell + YAML talking to the cluster through your current `kubectl` context.

## Layout

```
service-types-examples/
├── README.md
├── setup-service-types.sh
├── teardown-service-types.sh
└── manifests/
    ├── 00-namespace.yaml
    ├── 10-deployment-backend.yaml      # 3 nginx replicas, used by all selector-based svcs
    ├── 20-clusterip-service.yaml       # type: ClusterIP   (default)
    ├── 30-nodeport-service.yaml        # type: NodePort    (port 30090)
    ├── 40-loadbalancer-service.yaml    # type: LoadBalancer (needs MetalLB)
    ├── 50-externalname-service.yaml    # type: ExternalName -> example.com
    └── 60-headless-service.yaml        # clusterIP: None
```

## Prerequisites

- A running cluster (e.g. built by [../k8s-setup-w-cilium/playbooks/install-cluster.yaml](../k8s-setup-w-cilium/playbooks/install-cluster.yaml)).
- A merged kubeconfig on the workstation. Use [../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh](../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh) and verify with `kubectl config current-context` before running anything here.
- For the LoadBalancer example only: [../metallb-installation/](../metallb-installation/) installed first. Without MetalLB, `web-loadbalancer` will sit in `EXTERNAL-IP <pending>` forever — this is expected and a teaching point.

All five Services live in the **`svc-types-demo`** namespace. Nothing in `kube-system` or `default` is touched.

## Usage

### Lazy path

```shell
# Point kubectl at the cluster
bash ../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh
kubectl config current-context   # should be cilium-lab

# Apply everything in numeric order
bash setup-service-types.sh

# ... explore (see "Try it out" section below) ...

# Delete everything in reverse order
bash teardown-service-types.sh
```

### Manual path

Apply files one at a time and read the header comments — each YAML explains what to expect and how to test it:

```shell
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-deployment-backend.yaml
kubectl -n svc-types-demo rollout status deploy/web-backend

kubectl apply -f manifests/20-clusterip-service.yaml
kubectl apply -f manifests/30-nodeport-service.yaml
kubectl apply -f manifests/40-loadbalancer-service.yaml
kubectl apply -f manifests/50-externalname-service.yaml
kubectl apply -f manifests/60-headless-service.yaml

kubectl -n svc-types-demo get svc -o wide
```

Or all at once: `kubectl apply -f manifests/`.

## Try it out

### 1. ClusterIP — `web-clusterip`

Reachable only from inside the cluster:

```shell
kubectl -n svc-types-demo run curl --rm -it --image=curlimages/curl --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6; do curl -s http://web-clusterip/ | grep "<h1>"; done'
```

You should see the `<h1>Hello from web-backend-...</h1>` line cycle across 3 pod names.

### 2. NodePort — `web-nodeport` (port 30090 on every node)

Reachable from the workstation via any node IP:

```shell
for ip in 192.168.48.31 192.168.48.32 192.168.48.33 192.168.48.34; do
  curl -s http://${ip}:30090/ | grep '<h1>'
done
```
```shell
for ip in 192.168.48.31 192.168.48.32 192.168.48.33 192.168.48.34; do
  curl -s http://${ip}:30090/ 
done
```

Default `externalTrafficPolicy: Cluster` means traffic hitting node N may be forwarded to a pod on node M (extra hop, source IP SNATed). Switch to `Local` to preserve client IP at the cost of dropping traffic on nodes without a backend pod — see the comment block in [manifests/30-nodeport-service.yaml](manifests/30-nodeport-service.yaml).

### 3. LoadBalancer — `web-loadbalancer`

Needs MetalLB. Once installed:

```shell
IP=$(kubectl -n svc-types-demo get svc web-loadbalancer \
       -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "EXTERNAL-IP: ${IP}"
for i in 1 2 3 4 5 6; do curl -s http://${IP}/ | grep '<h1>'; done
```

If `${IP}` is empty:

- `kubectl -n svc-types-demo describe svc web-loadbalancer` — look for events.
- `kubectl get svc -A | grep LoadBalancer` — make sure the MetalLB pool isn't exhausted by other Services (e.g. the `test-service` stub from `metallb-installation/setup-metallb.sh`, or the ingress-nginx controller pinned to `192.168.48.201`).

To pin a specific IP across reinstalls, uncomment the `metallb.universe.tf/loadBalancerIPs` annotation in [manifests/40-loadbalancer-service.yaml](manifests/40-loadbalancer-service.yaml). The IP must be inside the MetalLB pool range (default `192.168.48.201-205`).

### 4. ExternalName — `web-external`

No proxy, no pods, no selector — just a CoreDNS CNAME pointing `web-external.svc-types-demo.svc.cluster.local` at `example.com`.

```shell
kubectl -n svc-types-demo run dns --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup web-external.svc-types-demo.svc.cluster.local
```

Expected output includes a `web-external.svc-types-demo.svc.cluster.local canonical name = example.com.` line followed by the resolved A record.

### 5. Headless — `web-headless` (`clusterIP: None`)

```shell
kubectl -n svc-types-demo run dns --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup web-headless.svc-types-demo.svc.cluster.local
```

You should see **3 A records** (one per ready backend pod), not a single VIP. Compare with the ClusterIP variant:

```shell
kubectl -n svc-types-demo run dns --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup web-clusterip.svc-types-demo.svc.cluster.local
```

— that one returns one A record (the VIP).

## Teardown

```shell
bash teardown-service-types.sh
```

The script walks `manifests/` in reverse order with `--ignore-not-found`, then waits for the `svc-types-demo` namespace to terminate. Re-running on a partially-installed cluster is safe.

A simpler one-liner that achieves the same end-state (the namespace owns everything except the cluster-scoped Service objects, which are namespaced anyway):

```shell
kubectl delete namespace svc-types-demo
```

## Where to go next

- Add a `topologyKeys`/`internalTrafficPolicy: Local` example to demonstrate topology-aware routing.
- Combine `web-loadbalancer` with [../ingress-nginx-w-certificate/](../ingress-nginx-w-certificate/) — point an Ingress at `web-clusterip` and reach it via the ingress controller's MetalLB IP, instead of giving the demo Service its own LB IP.
- Convert `web-headless` to back a `StatefulSet` and observe per-pod DNS names of the form `<pod-name>.web-headless.svc-types-demo.svc.cluster.local`.
