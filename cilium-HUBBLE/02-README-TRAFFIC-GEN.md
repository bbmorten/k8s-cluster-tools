# Generating Cross-Namespace Traffic to `nginx-demo`

After applying [tests/nginx-4-instances.yaml](tests/nginx-4-instances.yaml), the service `nginx-hello.nginx-demo.svc.cluster.local:80` is reachable cluster-wide. These snippets drive traffic to it from a pod in a **different** namespace — useful for exercising Cilium NetworkPolicies and watching flows in Hubble.

## One-shot curl from an ephemeral pod

```
kubectl create namespace traffic-gen

kubectl -n traffic-gen run curl --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -s http://nginx-hello.nginx-demo.svc.cluster.local/
```

## Continuous traffic (loop every 1s)

```
kubectl -n traffic-gen run curl-loop \
  --image=curlimages/curl:8.10.1 --restart=Never -- \
  sh -c 'while true; do curl -s -o /dev/null -w "%{http_code} " http://nginx-hello.nginx-demo.svc.cluster.local/; sleep 1; done'

kubectl -n traffic-gen logs -f curl-loop
```

## Watch it in Hubble

From the host, with `cilium hubble port-forward` running (see [README-HUBBLE.md](README-HUBBLE.md)):

```
hubble observe --namespace nginx-demo --follow

# Filter by the client namespace:
hubble observe --from-namespace traffic-gen --to-namespace nginx-demo --follow
```

## Observation points

| Observation Point | Where It Is | What It Means |
|---|---|---|
| `from-endpoint` | Just after leaving a local pod | Packet just left the source pod's network namespace |
| `to-endpoint` | Just before delivery to a local pod | Packet is about to enter the destination pod's network namespace |
| `to-overlay` | Just before VXLAN/Geneve encapsulation | Packet is leaving this node, headed to another node via the tunnel |
| `from-overlay` | Just after VXLAN/Geneve decapsulation | Packet arrived from another node and was just decapsulated |
| `to-network` | Egress in native-routing mode | Packet leaves the node via the underlying network without encapsulation |
| `from-network` | Ingress in native-routing mode | Packet arrived from the underlying network without decapsulation |
| `to-stack` | Boundary into the host kernel network stack | Packet handed off to the Linux stack (host networking, kube-proxy fallbacks, etc.) |
| `from-stack` | Boundary out of the host kernel network stack | Packet received from the Linux stack into Cilium's datapath |
| `to-proxy` | Entering Envoy / DNS proxy | L7 policy enforcement is being applied |
| `from-proxy` | Leaving Envoy / DNS proxy | Packet returning from L7 proxy back into the datapath |

## Cleanup

```
kubectl delete namespace traffic-gen
```
