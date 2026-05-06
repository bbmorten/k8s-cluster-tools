#!/bin/bash
# RBAC user lab — setup
# Issues an x509 client cert via the cluster's CSR API for a user whose only
# authority is to *create* Deployments in a single namespace, then writes a
# self-contained kubeconfig the student can copy to another host.

set -euo pipefail

USER_NAME="${USER_NAME:-dev-deploy}"
GROUP="${GROUP:-developers}"
NAMESPACE="${NAMESPACE:-dev-apps}"
CLUSTER_API="${CLUSTER_API:-https://192.168.48.31:6443}"
CLUSTER_NAME="${CLUSTER_NAME:-cilium-lab}"
CSR_DURATION="${CSR_DURATION:-31536000}"   # 365 days, clamped by kube-controller-manager
OUTPUT_DIR="${OUTPUT_DIR:-./kubeconfigs}"
KUBECONFIG_OUT="${OUTPUT_DIR}/${USER_NAME}.kubeconfig"

mkdir -p "${OUTPUT_DIR}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

echo "==> Checking admin context"
kubectl config current-context
kubectl auth can-i approve certificatesigningrequests.certificates.k8s.io/kubernetes.io/kube-apiserver-client >/dev/null \
  || { echo "ERROR: current context cannot approve CSRs — fetch an admin kubeconfig first" >&2; exit 1; }

echo "==> Step 1: Generating private key and CSR for CN=${USER_NAME}, O=${GROUP}"
openssl genrsa -out "${WORKDIR}/${USER_NAME}.key" 2048 2>/dev/null
openssl req -new -key "${WORKDIR}/${USER_NAME}.key" \
  -out "${WORKDIR}/${USER_NAME}.csr" \
  -subj "/CN=${USER_NAME}/O=${GROUP}"

echo "==> Step 2: Submitting CertificateSigningRequest '${USER_NAME}'"
# CSRs are immutable; remove any leftover from a previous run before re-applying.
kubectl delete csr "${USER_NAME}" --ignore-not-found
CSR_B64=$(base64 -w 0 < "${WORKDIR}/${USER_NAME}.csr")
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${CSR_DURATION}
  usages:
  - client auth
EOF

echo "==> Step 3: Approving CSR"
kubectl certificate approve "${USER_NAME}"

echo "==> Step 4: Waiting for kube-controller-manager to sign"
CERT=""
for _ in $(seq 1 30); do
  CERT=$(kubectl get csr "${USER_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null || true)
  [[ -n "${CERT}" ]] && break
  sleep 1
done
[[ -n "${CERT}" ]] || { echo "ERROR: CSR was not signed within 30s" >&2; exit 1; }
echo "${CERT}" | base64 -d > "${WORKDIR}/${USER_NAME}.crt"

echo "==> Step 5: Creating namespace '${NAMESPACE}'"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Step 6: Creating Role + RoleBinding (verb=create, resource=deployments)"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-creator
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployment-creator-binding
  namespace: ${NAMESPACE}
subjects:
- kind: User
  name: ${USER_NAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: deployment-creator
  apiGroup: rbac.authorization.k8s.io
EOF

echo "==> Step 7: Building self-contained kubeconfig at ${KUBECONFIG_OUT}"
CA_DATA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [[ -z "${CA_DATA}" ]]; then
  CA_FILE=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  [[ -n "${CA_FILE}" && -f "${CA_FILE}" ]] || { echo "ERROR: cannot locate cluster CA" >&2; exit 1; }
  CA_DATA=$(base64 -w 0 < "${CA_FILE}")
fi
CRT_DATA=$(base64 -w 0 < "${WORKDIR}/${USER_NAME}.crt")
KEY_DATA=$(base64 -w 0 < "${WORKDIR}/${USER_NAME}.key")

cat > "${KUBECONFIG_OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: ${CLUSTER_API}
    certificate-authority-data: ${CA_DATA}
users:
- name: ${USER_NAME}
  user:
    client-certificate-data: ${CRT_DATA}
    client-key-data: ${KEY_DATA}
contexts:
- name: ${USER_NAME}@${CLUSTER_NAME}
  context:
    cluster: ${CLUSTER_NAME}
    user: ${USER_NAME}
    namespace: ${NAMESPACE}
current-context: ${USER_NAME}@${CLUSTER_NAME}
EOF
chmod 600 "${KUBECONFIG_OUT}"

echo "==> Step 8: Verifying RBAC matrix from the new user's perspective"
KC="--kubeconfig=${KUBECONFIG_OUT}"
printf '  create deployments in %-15s : %s\n' "${NAMESPACE}" "$(kubectl ${KC} auth can-i create deployments -n "${NAMESPACE}")"
printf '  list   deployments in %-15s : %s\n' "${NAMESPACE}" "$(kubectl ${KC} auth can-i list   deployments -n "${NAMESPACE}")"
printf '  create deployments in %-15s : %s\n' "default"      "$(kubectl ${KC} auth can-i create deployments -n default)"
printf '  create pods        in %-15s : %s\n' "${NAMESPACE}" "$(kubectl ${KC} auth can-i create pods        -n "${NAMESPACE}")"

cat <<EOF

Done.

  kubeconfig : ${KUBECONFIG_OUT}
  user       : ${USER_NAME}  (group: ${GROUP})
  namespace  : ${NAMESPACE}
  api server : ${CLUSTER_API}

Try it:
  kubectl --kubeconfig=${KUBECONFIG_OUT} create deployment nginx --image=nginx
  kubectl --kubeconfig=${KUBECONFIG_OUT} get deployments         # Forbidden — no 'get' verb

Copy to another host (must be able to reach ${CLUSTER_API}):
  scp ${KUBECONFIG_OUT} user@otherhost:~/
EOF
