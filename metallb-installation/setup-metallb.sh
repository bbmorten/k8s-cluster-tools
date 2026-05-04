#!/bin/bash
# MetalLB Installation and Configuration Guide
# This script provides steps to install MetalLB and configure it with IP range 192.168.48.135-140

# Step 1: Install MetalLB using manifest
#kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.10/config/manifests/metallb-native.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml

# Wait for MetalLB to be ready
echo "Waiting for MetalLB components to be ready..."
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Step 2: Configure the IP address pool
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.48.201-192.168.48.205
EOF

# Step 3: Configure the L2 announcement
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF

# Step 4: Verify installation
echo "Verifying MetalLB installation..."
kubectl get pods -n metallb-system

# Step 5: Create a test service to verify IP allocation (optional)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: default
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: test-app  # This selector won't match anything as this is just a test
  type: LoadBalancer
EOF

# Check if the service got an IP address
echo "Checking if test service got an IP from MetalLB..."
kubectl get service test-service

echo "MetalLB has been installed and configured with IP range 192.168.48.201-192.168.48.205"
echo "To use it with your existing ingress controller, change the service type to LoadBalancer:"
echo "kubectl patch svc nginx-ingress-ingress-nginx-controller -n ingress-nginx -p '{\"spec\":{\"type\":\"LoadBalancer\"}}'"

# Optional: Clean up the test service
# kubectl delete service test-service