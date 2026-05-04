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

## Cleanup

```
kubectl delete namespace traffic-gen
```
