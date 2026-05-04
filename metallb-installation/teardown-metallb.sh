#!/bin/bash
# MetalLB Teardown Script
# Reverses the actions performed by setup-metallb.sh:
#   - Removes the test LoadBalancer service
#   - Removes the L2Advertisement and IPAddressPool
#   - Uninstalls MetalLB itself (CRDs, controller, speaker, namespace)

set -u

METALLB_MANIFEST="https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml"

# Step 1: Delete the test service (created in setup step 5)
echo "Deleting test service..."
kubectl delete service test-service -n default --ignore-not-found

# Step 2: Delete the L2Advertisement (created in setup step 3)
echo "Deleting L2Advertisement 'l2-advertisement'..."
kubectl delete l2advertisement l2-advertisement -n metallb-system --ignore-not-found

# Step 3: Delete the IPAddressPool (created in setup step 2)
echo "Deleting IPAddressPool 'first-pool'..."
kubectl delete ipaddresspool first-pool -n metallb-system --ignore-not-found

# Step 4: Uninstall MetalLB itself (created in setup step 1)
# Deleting the manifest removes the namespace, controller, speaker DaemonSet,
# webhooks, RBAC, and CRDs that were applied by the install.
echo "Uninstalling MetalLB via manifest..."
kubectl delete -f "${METALLB_MANIFEST}" --ignore-not-found

# Step 5: Wait for the namespace to fully terminate
echo "Waiting for metallb-system namespace to terminate..."
kubectl wait --for=delete namespace/metallb-system --timeout=120s 2>/dev/null || true

# Step 6: Verify cleanup
echo "Verifying teardown..."
if kubectl get namespace metallb-system >/dev/null 2>&1; then
  echo "WARNING: namespace 'metallb-system' still exists:"
  kubectl get all -n metallb-system
else
  echo "Namespace 'metallb-system' is gone."
fi

remaining_crds=$(kubectl get crds -o name 2>/dev/null | grep 'metallb.io' || true)
if [ -n "${remaining_crds}" ]; then
  echo "WARNING: MetalLB CRDs still present:"
  echo "${remaining_crds}"
else
  echo "No MetalLB CRDs remain."
fi

echo "MetalLB teardown complete."
echo "If you patched an ingress controller to type=LoadBalancer, revert it manually, e.g.:"
echo "  kubectl patch svc nginx-ingress-ingress-nginx-controller -n ingress-nginx -p '{\"spec\":{\"type\":\"NodePort\"}}'"
