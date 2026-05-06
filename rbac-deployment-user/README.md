# rbac-deployment-user

Hands-on lab that creates a dedicated Kubernetes user (`dev-deploy`) whose only authority is to **create Deployments** in a single namespace (`dev-apps`). The lab issues an x509 client certificate via the cluster's CertificateSigningRequest API, binds the user to a minimal Role, and writes a self-contained kubeconfig file that can be copied to another machine and used directly.

This is a teaching demo of Kubernetes RBAC + cert-based authn, not a production identity flow — there's no IdP, no token rotation, and the cert is signed by the cluster's own CA.

Same shape as [../metallb-installation/](../metallb-installation/): two shell scripts that talk to the cluster through the caller's current `kubectl` context. No Ansible, no inventory, nothing installed on the nodes themselves — every object lives inside the cluster (a CSR, a namespace, a Role, a RoleBinding) plus one local kubeconfig file.

## Layout

```
rbac-deployment-user/
├── README.md
├── setup-rbac-user.sh      # genkey + CSR + approve + RBAC + write kubeconfig
└── teardown-rbac-user.sh   # delete RBAC objects, namespace, CSR, local kubeconfig
```

## Prerequisites

- A running cluster (e.g. built by [../k8s-setup-w-cilium/](../k8s-setup-w-cilium/)). Control-plane API endpoint is `https://192.168.48.31:6443` in this repo.
- A merged kubeconfig **with cluster-admin rights** on the workstation. Use [../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh](../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh) and verify with `kubectl config current-context` (should be `cilium-lab`) before running these scripts.
- `openssl` and GNU `base64` (both ship with Ubuntu 24.04 by default).
- The control-plane API endpoint must be reachable from any host you intend to use the generated kubeconfig from.

## Configuration

Defaults are pinned at the top of [setup-rbac-user.sh](setup-rbac-user.sh) and can be overridden by environment variable:

| Variable | Default | Description |
|---|---|---|
| `USER_NAME` | `dev-deploy` | x509 CN — what `kubectl` reports as the user |
| `GROUP` | `developers` | x509 O — bound as group, useful if you extend RBAC later |
| `NAMESPACE` | `dev-apps` | namespace the user can create Deployments in |
| `CLUSTER_API` | `https://192.168.48.31:6443` | API server endpoint baked into the kubeconfig |
| `CLUSTER_NAME` | `cilium-lab` | cluster name used in the kubeconfig (matches `fetch-kubeconfig.sh`) |
| `CSR_DURATION` | `31536000` (365 d) | requested cert lifetime in seconds |
| `OUTPUT_DIR` | `./kubeconfigs` | where the generated kubeconfig is written |

## Lazy path (scripts)

```shell
# Point kubectl at the cluster as cluster-admin first
bash ../k8s-setup-w-cilium/scripts/fetch-kubeconfig.sh
kubectl config current-context     # should be cilium-lab

# Generate user, RBAC, and kubeconfig
bash setup-rbac-user.sh

# Use it
kubectl --kubeconfig=kubeconfigs/dev-deploy.kubeconfig create deployment nginx --image=nginx

# Tear it all down
bash teardown-rbac-user.sh
```

## Step-by-step (manual walkthrough)

If you're doing this for the first time, run the lab by hand once. Every step below is what `setup-rbac-user.sh` automates.

### 1. Generate a private key and CSR

```shell
WORK=$(mktemp -d)
openssl genrsa -out "${WORK}/dev-deploy.key" 2048
openssl req -new -key "${WORK}/dev-deploy.key" \
  -out "${WORK}/dev-deploy.csr" \
  -subj "/CN=dev-deploy/O=developers"
```

`CN` becomes the username; `O` becomes a group. Kubernetes does **not** maintain a user database — the API server trusts whatever CN appears in a cert signed by its own client CA.

### 2. Submit the CSR to Kubernetes

```shell
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: dev-deploy
spec:
  request: $(base64 -w 0 < "${WORK}/dev-deploy.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
  - client auth
EOF
```

`signerName: kubernetes.io/kube-apiserver-client` tells kube-controller-manager to sign the request with the cluster's client CA once it's approved.

### 3. Approve the CSR

```shell
kubectl certificate approve dev-deploy
kubectl get csr dev-deploy
```

The `CONDITION` column should flip from `Pending` to `Approved,Issued` within a second or two.

### 4. Extract the signed certificate

```shell
kubectl get csr dev-deploy -o jsonpath='{.status.certificate}' \
  | base64 -d > "${WORK}/dev-deploy.crt"
```

### 5. Create the namespace and RBAC

```shell
kubectl create namespace dev-apps

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-creator
  namespace: dev-apps
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployment-creator-binding
  namespace: dev-apps
subjects:
- kind: User
  name: dev-deploy
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: deployment-creator
  apiGroup: rbac.authorization.k8s.io
EOF
```

The Role grants exactly **one** verb (`create`) on **one** resource (`deployments` in apiGroup `apps`). Anything else — `get`, `list`, `delete`, or any other resource — will be denied. That's deliberate; it makes the boundary visible.

### 6. Build the kubeconfig

```shell
CA_DATA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
CRT_DATA=$(base64 -w 0 < "${WORK}/dev-deploy.crt")
KEY_DATA=$(base64 -w 0 < "${WORK}/dev-deploy.key")

cat > dev-deploy.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: cilium-lab
  cluster:
    server: https://192.168.48.31:6443
    certificate-authority-data: ${CA_DATA}
users:
- name: dev-deploy
  user:
    client-certificate-data: ${CRT_DATA}
    client-key-data: ${KEY_DATA}
contexts:
- name: dev-deploy@cilium-lab
  context:
    cluster: cilium-lab
    user: dev-deploy
    namespace: dev-apps
current-context: dev-deploy@cilium-lab
EOF
chmod 600 dev-deploy.kubeconfig
```

The kubeconfig is now self-contained: CA, client cert, and key are all base64-embedded, so it can be moved anywhere.

### 7. Verify the RBAC boundary

```shell
KC=--kubeconfig=dev-deploy.kubeconfig

# Allowed
kubectl ${KC} create deployment nginx --image=nginx
# expected: deployment.apps/nginx created

# Denied — no 'get' verb on the Role
kubectl ${KC} get deployments
# expected: Error from server (Forbidden): deployments.apps is forbidden

# Denied — wrong namespace
kubectl ${KC} create deployment nginx --image=nginx -n default
# expected: Error from server (Forbidden): ... in the namespace "default"

# Quick allow/deny matrix:
kubectl ${KC} auth can-i create deployments -n dev-apps   # yes
kubectl ${KC} auth can-i list   deployments -n dev-apps   # no
kubectl ${KC} auth can-i create pods         -n dev-apps  # no
```

## Using the kubeconfig from another host

The kubeconfig is fully self-contained, so copy it anywhere that can reach the API server:

```shell
scp kubeconfigs/dev-deploy.kubeconfig user@otherhost:~/
ssh user@otherhost
export KUBECONFIG=~/dev-deploy.kubeconfig
kubectl create deployment hello --image=nginx       # works
kubectl get deployments                             # Forbidden
```

`192.168.48.31:6443` must be routable from that host. If you're outside the lab subnet you'll need a port-forward, VPN, or to bake a different `CLUSTER_API` into the kubeconfig at generation time:

```shell
CLUSTER_API=https://k8s.example.com:6443 bash setup-rbac-user.sh
```

## What teardown does

[teardown-rbac-user.sh](teardown-rbac-user.sh) reverses the install in this order:

1. `kubectl delete rolebinding deployment-creator-binding -n dev-apps`
2. `kubectl delete role deployment-creator -n dev-apps`
3. `kubectl delete namespace dev-apps` (also wipes any Deployments the user created)
4. `kubectl delete csr dev-deploy`
5. `rm -f kubeconfigs/dev-deploy.kubeconfig`

Every `kubectl delete` uses `--ignore-not-found`, so re-running on a partially-installed lab is safe. Resources the user created via the kubeconfig are deleted with the namespace; RBAC would have refused any cross-namespace writes, so there is nothing else to clean up.

The issued client certificate cannot be revoked — Kubernetes has no CRL — but with no Role/RoleBinding pointing at `dev-deploy`, the cert authenticates as a user with zero permissions until it expires.

## Troubleshooting

- **CSR stays `Pending`** — you need cluster-admin to approve. `kubectl auth can-i approve certificatesigningrequests.certificates.k8s.io/kubernetes.io/kube-apiserver-client` should return `yes`. The setup script enforces this up front.
- **`status.certificate` is empty after approval** — kube-controller-manager signs CSRs; check `kubectl logs -n kube-system kube-controller-manager-<cp-host>` if it stays empty for more than a few seconds.
- **`x509: certificate signed by unknown authority` when using the kubeconfig** — the embedded CA does not match what the API server presents. Re-run setup; the script always re-extracts the live CA. Don't hand-edit `certificate-authority-data` in the kubeconfig.
- **`Forbidden` on `kubectl get deploy`** — that's correct. The user has only `create`. Add a `get`/`list` verb to the Role if you want to allow it; demonstrating this denial is the lab's main lesson.
- **Cert lifetime shorter than `CSR_DURATION`** — kubeadm runs kube-controller-manager with `--cluster-signing-duration` (default 365 d). Requesting more clamps to the signer's max.
- **Re-running setup fails on `CertificateSigningRequest` apply** — CSRs are immutable once submitted. The script `kubectl delete`s any existing CSR with the same name before re-applying; if you ran the manual walkthrough by hand, do the same: `kubectl delete csr dev-deploy` before re-submitting.
