# ingress-nginx-w-certificate

Lab demo for **ingress-nginx** with TLS at the edge and two different backend modes:

- `test-ingress-1.example.com/{a,b,c}` → ingress terminates TLS, talks **HTTP** to pods in namespace `test-ingress-1`.
- `test-ingress-2.example.com/{a,b,c}` → ingress terminates TLS, **re-encrypts and talks HTTPS** to pods in namespace `test-ingress-2`.

Both hostnames share a single self-signed cert with SANs for both names. Both ingresses share the same MetalLB LoadBalancer IP.

## Layout

```
ingress-nginx-w-certificate/
├── create-tls-secret.sh                # SAN cert → kubernetes.io/tls Secret in both namespaces
├── setup-ingress-demo.sh               # 5-step install
├── teardown-ingress-demo.sh            # 5-step reverse
└── manifests/
    ├── backends-test-ingress-1.yaml    # 3× HTTP backends  (web-a, web-b, web-c) + ConfigMap
    ├── backends-test-ingress-2.yaml    # 3× HTTPS backends (web-a, web-b, web-c) + ConfigMap + TLS mount
    ├── ingress-test-ingress-1.yaml     # Ingress, HTTP backends
    └── ingress-test-ingress-2.yaml     # Ingress, backend-protocol=HTTPS (re-encrypt)
```

## Prerequisites

- A Kubernetes cluster from [../k8s-setup-w-cilium/](../k8s-setup-w-cilium/) (or equivalent), reachable via your current `kubectl` context.
- **MetalLB installed** ([../metallb-installation/](../metallb-installation/)) — the ingress-nginx Service is `type: LoadBalancer` and needs a pool to draw from. Default pool is `192.168.48.201-192.168.48.205`.
- `openssl`, `kubectl`, `bash` on the workstation.

## Versions

Pinned inline in [setup-ingress-demo.sh](setup-ingress-demo.sh) and [teardown-ingress-demo.sh](teardown-ingress-demo.sh):

- ingress-nginx **`controller-v1.15.1`** (the final release — see [archive note](#about-the-archived-controller))
- nginx backend image: `nginx:1.27-alpine`

To bump the controller, override `INGRESS_NGINX_VERSION` in the environment, or edit both scripts so install/teardown agree.

## Usage

```shell
# Install (idempotent — re-runs replace existing TLS secret + Ingress objects)
./setup-ingress-demo.sh

# Optional overrides
LB_IP=192.168.48.202 INGRESS_NGINX_VERSION=controller-v1.15.1 ./setup-ingress-demo.sh

# Tear down
./teardown-ingress-demo.sh
```

After install, add the LB IP to `/etc/hosts` on the **client** machine doing the curls:

```
192.168.48.201  test-ingress-1.example.com test-ingress-2.example.com
```

Then probe each path (cert is self-signed, hence `-k`):

```shell
for h in test-ingress-1 test-ingress-2; do
  for p in a b c; do
    echo "--- $h.example.com/$p"
    curl -sk "https://$h.example.com/$p"
  done
done
```

Each request returns plain-text output identifying the pod that served it, e.g.:

```
host=test-ingress-1.example.com pod=web-a-7df6c4b9bd-xj2gk ns=test-ingress-1 letter=a path=/a scheme=http
host=test-ingress-2.example.com pod=web-a-6f8b94c66c-9wlmh ns=test-ingress-2 letter=a path=/a scheme=https
```

The `scheme=` value distinguishes the two hosts: `http` for `test-ingress-1` (controller→pod is plaintext), `https` for `test-ingress-2` (controller→pod is TLS, then `$scheme` inside the pod is `https`).

## What setup does

1. **Install ingress-nginx** from the upstream static `cloud` provider manifest pinned to `controller-v1.15.1`. Waits for the controller Deployment to roll out.
2. **Pin the controller Service to `LB_IP`** via the `metallb.universe.tf/loadBalancerIPs` annotation so the external DNS / hosts file entry stays valid across teardown+reinstall cycles.
3. **Generate cert + push secret** by invoking [create-tls-secret.sh](create-tls-secret.sh):
   - one self-signed cert with `subjectAltName = DNS:test-ingress-1.example.com, DNS:test-ingress-2.example.com`
   - applied as Secret `example-tls` in both demo namespaces (using `kubectl create … --dry-run=client -o yaml | kubectl apply` for re-runnability)
4. **Apply backends:**
   - `test-ingress-1`: ConfigMap with HTTP-only nginx template + 3 Deployments (`web-a/b/c`) + 3 Services on `:80`.
   - `test-ingress-2`: ConfigMap with HTTPS nginx template (cert mounted from the same `example-tls` Secret) + 3 Deployments + 3 Services on `:443`.
   - Waits for all 6 Deployments to reach `Available`.
5. **Apply Ingress resources** — both with a `tls:` block referencing `example-tls`; `test-ingress-2`'s also carries `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"`.

## Design notes

### Why re-encrypt instead of SSL passthrough for `test-ingress-2`?

ingress-nginx's `ssl-passthrough` mode TCP-forwards the encrypted client stream straight to the pod, so the controller **never sees the path** — it routes only by SNI hostname. That's incompatible with the `/a /b /c` path-based fan-out this demo asks for. Re-encrypt (controller decrypts, inspects the path, re-encrypts to upstream) preserves path routing. The annotation is `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"`.

### Why don't we verify the upstream cert?

Defaulted off because the pod cert is self-signed by the same script that generates the edge cert. To turn upstream verification on you'd add to the test-ingress-2 Ingress:

```yaml
nginx.ingress.kubernetes.io/proxy-ssl-verify: "on"
nginx.ingress.kubernetes.io/proxy-ssl-secret: "test-ingress-2/example-tls"
```

…and ensure the Secret contains a `ca.crt` that signs the upstream cert (would mean making this a small CA + leaf, not a single self-signed leaf).

### Why one SAN cert instead of two?

With one cert containing both names as SANs, the same Secret is reused unchanged in both namespaces — simpler than maintaining two CAs or two cert lifecycles, and the browser/curl warnings are identical for both hostnames (just the self-signed warning, no SAN-mismatch on top).

### How the pods identify themselves

Each backend Deployment uses the official `nginx` image's built-in template feature (`/etc/nginx/templates/*.template` → `envsubst` → `/etc/nginx/conf.d/`). The Deployment exports four env vars:

- `POD_NAME` (Downward API: `metadata.name`)
- `POD_NAMESPACE` (Downward API: `metadata.namespace`)
- `SERVICE_LABEL` (`a` / `b` / `c`, hardcoded per Deployment)
- `NGINX_ENVSUBST_FILTER="POD_NAME|POD_NAMESPACE|SERVICE_LABEL"`

The filter is critical: without it, `envsubst` would also try to expand nginx variables like `$host`, `$request_uri`, `$scheme` in the template (since they share `$VAR` syntax), substituting them to empty strings and breaking the config. With the filter, only those three names are touched; nginx's own variables pass through verbatim and are evaluated at request time.

### LoadBalancer IP coupling

`setup-ingress-demo.sh` pins the controller Service to a single MetalLB IP (`192.168.48.201` by default). MetalLB's `first-pool` covers `.201–.205`, so this IP is always available unless something else has claimed it. If your MetalLB pool is different, override with `LB_IP=...`.

### Path routing semantics

`pathType: Prefix` matches `/a` *and* `/a/anything`. If you want strict matching (no subpaths), switch the four Ingress entries (3 paths × 2 ingresses) to `pathType: Exact`. Prefix is friendlier when poking around with curl.

## Verifying without DNS

If you don't want to edit `/etc/hosts`, fake the Host header with curl:

```shell
LB_IP=192.168.48.201
curl -sk -H "Host: test-ingress-1.example.com" "https://${LB_IP}/a" \
  --resolve "test-ingress-1.example.com:443:${LB_IP}"
curl -sk -H "Host: test-ingress-2.example.com" "https://${LB_IP}/a" \
  --resolve "test-ingress-2.example.com:443:${LB_IP}"
```

`--resolve` is the cleanest form because it makes the SNI value match the Host header (curl uses the resolved name for SNI), so the ingress picks the correct TLS cert + Ingress rule.

## Teardown order

[teardown-ingress-demo.sh](teardown-ingress-demo.sh) reverses the install in this order:

1. Ingress resources (so the controller stops routing into namespaces about to disappear).
2. Backend Deployments / Services / ConfigMaps.
3. TLS Secrets in both namespaces.
4. Demo namespaces (`test-ingress-1`, `test-ingress-2`).
5. ingress-nginx controller manifest (Deployment, Service, RBAC, IngressClass, admission webhook).

The script then waits up to 120s for the `ingress-nginx` namespace to terminate and reports any leftover demo namespaces. CRDs aren't expected here — ingress-nginx in cloud-provider mode doesn't ship custom CRDs.

## About the archived controller

The upstream `kubernetes/ingress-nginx` repo was archived **2026-03-24** with `controller-v1.15.1` as the final release. It still works fine for a homelab and is what this folder pins. If you want to track an actively-maintained successor, look at:

- **Ingate** — the community successor positioned as a drop-in replacement.
- **Gateway API + a Gateway controller** (Cilium itself implements Gateway API; you already have Cilium on this cluster).

To swap controllers, change `INGRESS_NGINX_VERSION` (and the manifest URL pattern in both scripts) to the successor's release; the backend manifests in this folder are vanilla Kubernetes objects and don't depend on the controller's identity beyond the `ingressClassName: nginx` field.
