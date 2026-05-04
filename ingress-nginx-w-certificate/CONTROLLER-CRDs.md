# How controllers use CRDs

A **controller** is a control loop that watches Kubernetes resources and works to make the cluster's actual state match the desired state declared in those resources. **CRDs (Custom Resource Definitions)** let you teach the Kubernetes API server about new resource types beyond the built-ins like Pod and Deployment. A controller paired with a CRD is what people call an **Operator**.

## The mental model

A CRD is just a *schema* — it tells the API server "here's a new kind called `PostgresCluster`, here's its OpenAPI schema, store instances of it in etcd." The CRD itself does nothing. It's inert YAML in the cluster.

The **controller** is the thing that gives the CRD meaning. It watches for instances of that custom resource and takes action to make reality match the spec.

```
┌─────────────────────────────────────────────────────────────┐
│  User writes:                                                │
│    kind: PostgresCluster                                     │
│    spec: { replicas: 3, version: "16" }                      │
└──────────────────────┬──────────────────────────────────────┘
                       │ kubectl apply
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  API Server validates against CRD schema, stores in etcd     │
└──────────────────────┬──────────────────────────────────────┘
                       │ watch event
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Controller's reconcile loop:                                │
│    1. Read PostgresCluster object                            │
│    2. Compare to actual state (existing Pods, PVCs, etc.)    │
│    3. Create/update/delete child resources to match          │
│    4. Update .status on the CR                               │
└─────────────────────────────────────────────────────────────┘
```

## The reconcile loop

This is the heart of every controller. The pseudocode looks like this:

```go
func Reconcile(ctx context.Context, req Request) (Result, error) {
    // 1. Fetch the custom resource
    var cluster PostgresCluster
    if err := client.Get(ctx, req.NamespacedName, &cluster); err != nil {
        // Resource was deleted — clean up if needed
        return Result{}, client.IgnoreNotFound(err)
    }

    // 2. Observe actual state
    var pods PodList
    client.List(ctx, &pods, MatchingLabels{"cluster": cluster.Name})

    // 3. Compare desired vs actual, take action
    if len(pods.Items) < cluster.Spec.Replicas {
        createPod(ctx, &cluster)
    }
    if len(pods.Items) > cluster.Spec.Replicas {
        deletePod(ctx, pods.Items[0])
    }

    // 4. Update status
    cluster.Status.ReadyReplicas = countReady(pods)
    client.Status().Update(ctx, &cluster)

    // 5. Requeue if work remains
    return Result{RequeueAfter: 30 * time.Second}, nil
}
```

This function runs every time the CR changes, every time a watched child resource changes, and on a periodic resync. Crucially, it must be **idempotent** — running it 100 times in a row should produce the same end state as running it once.

## How the controller actually watches

Controllers don't poll. They use the API server's **watch** mechanism, which streams events. The controller-runtime library (used by most operators) wraps this in:

- An **informer** that maintains a local cache of all `PostgresCluster` objects
- A **work queue** that deduplicates events for the same object
- A **reconciler** that pulls from the queue and runs your `Reconcile` function

You also tell the controller which child resources to watch. If a Pod created by the controller dies, the controller gets notified and reconciles its owner CR — that's how self-healing emerges automatically.

```go
ctrl.NewControllerManagedBy(mgr).
    For(&PostgresCluster{}).        // primary resource
    Owns(&corev1.Pod{}).            // child resources to watch
    Owns(&corev1.PersistentVolumeClaim{}).
    Complete(reconciler)
```

## The CRD's two key sections: spec and status

By convention:

- **`spec`** — what the user wants. The controller reads this, never writes to it.
- **`status`** — what's actually happening. The controller writes this, the user only reads it.

This separation matters: it prevents fighting between user edits and controller updates. The CRD definition can mark `status` as a subresource so the controller updates status without bumping the spec's resourceVersion.

## What "uses" really looks like in practice

A real controller does several things with the CRD:

**Reads the spec to know what to build.** A `PostgresCluster` with `replicas: 3` causes the controller to create 3 StatefulSet pods, a Service, ConfigMaps for config, Secrets for credentials, PVCs for storage.

**Sets owner references on children.** Every child resource gets `ownerReferences` pointing to the CR. When the user deletes the `PostgresCluster`, Kubernetes garbage-collects all its children automatically.

**Writes status to communicate back.** Fields like `status.phase`, `status.readyReplicas`, `status.conditions[]` tell users what the controller is doing. `kubectl get postgrescluster` shows this.

**Handles finalizers.** Before allowing deletion, the controller can register a finalizer (e.g. `postgres.example.com/backup-before-delete`) that blocks deletion until the controller takes a final backup, then removes the finalizer.

**Validates and defaults.** The CRD's OpenAPI schema does basic validation; an admission webhook can do complex validation; the controller does runtime validation as a last resort.

## Where to start if you're building one

The standard tool is **kubebuilder** (or **operator-sdk**, which wraps it). Workflow:

```bash
kubebuilder init --domain example.com --repo github.com/me/postgres-operator
kubebuilder create api --group db --version v1 --kind PostgresCluster
```

This scaffolds the CRD types, the controller skeleton, and all the boilerplate. You fill in the Go struct for `Spec`/`Status` and the body of `Reconcile`.

## Common patterns worth knowing

- **Level-triggered, not edge-triggered** — the controller reconciles based on observed state, not on which event fired. If it misses an event, the next reconcile still converges.
- **Predictable child names** — name child resources deterministically (`mycluster-pod-0`) so the controller can find them again on restart without storing state.
- **Status conditions** — use the standard `metav1.Condition` pattern (`Ready`, `Progressing`, `Degraded`) for consistency with built-in resources.
- **Backoff on error** — return an error from `Reconcile` and controller-runtime requeues with exponential backoff automatically.

So: the CRD defines *what can be expressed*; the controller defines *what those expressions mean and how they get realized*. Neither is useful without the other.