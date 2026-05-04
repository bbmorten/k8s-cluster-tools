# Using Hubble with the Cilium CLI from the Remote Host

Run everything from your workstation (the host where you have `kubectl` and the merged kubeconfig produced by [scripts/fetch-kubeconfig.sh](scripts/fetch-kubeconfig.sh)). You need the `cilium` and `hubble` CLIs installed locally, Hubble enabled in the cluster, and a port-forward to the Hubble Relay.

## 1. Install the CLIs on the host

macOS:

```
brew install cilium-cli hubble
```

Linux:

```
# cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin

# hubble CLI
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz
sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
```

## 2. Point at the cluster

```
export KUBECONFIG=~/.kube/config
kubectl config use-context cilium-lab
cilium status --wait
```

## 3. Enable Hubble, Relay, and UI (one-time)

```
cilium hubble enable --ui
cilium status --wait
```

## 4. Open the Relay port

Keep this running in one terminal:

```
cilium hubble port-forward &
# listens on localhost:4245
```

## 5. Query flows from the host

```
hubble status
hubble observe
hubble observe --namespace default --follow
hubble observe --pod default/nginx --verdict DROPPED
```

## 6. Hubble UI in a browser

```
cilium hubble ui
# opens http://localhost:12000
```

## Teardown

```
cilium hubble disable
```

If `cilium status` shows Relay not ready, wait for the `hubble-relay` pod in `kube-system` before port-forwarding.
