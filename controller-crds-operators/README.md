# controller-crds-operators

A hands-on lab teaching **CustomResourceDefinitions (CRDs)** and **operators** by building a small but real `Website` operator with kubebuilder. The operator turns a single user-facing CR into a Deployment + Service + ConfigMap that serves arbitrary HTML through nginx.

The full design rationale and pedagogical theory live in [scenario.md](scenario.md). This README is the **runbook** — it tells students how to do the lab, and tells lazy students / instructors how to skip straight to the working demo.

## Two ways to do this lab

```
              ┌──────────────────────────────────┐
              │   How much do you want to type?  │
              └──────────────────────────────────┘
                  │                          │
        I want to learn it.            Just show me it works.
                  │                          │
                  ▼                          ▼
          [Step-by-step path]        [Lazy path — three scripts]
          read README + scenario,    ./prereq-check.sh
          run kubebuilder yourself,  ./setup-lab.sh
          paste the code in,         (open new terminal: `cd website-operator && make run`)
          run `make install run`     ./demo-magic.sh
                                     ./teardown-lab.sh
```

Both paths produce the same final state. The lazy path uses the scripts to scaffold the project, drop in the canonical solution from [solution/](solution/), and apply a sample CR; the controller process itself still has to be started by hand (`make run` is the foreground log-tailing command students should see).

## Layout

```
controller-crds-operators/
├── scenario.md              # Theory + design rationale (read this first if learning)
├── README.md                # You are here — runbook for both paths
├── prereq-check.sh          # Verify go / kubebuilder / kubectl / cluster access
├── setup-lab.sh             # Lazy path: scaffold + drop solution + install CRD + apply sample
├── teardown-lab.sh          # Reverse setup: delete CRs, uninstall CRD, remove scaffold dir
├── demo-magic.sh            # Run the 5 "wow" demos (self-heal, cascade, validation, ...)
├── solution/
│   ├── website_types.go             # Drop-in for api/v1/website_types.go
│   ├── website_controller.go        # Drop-in for internal/controller/website_controller.go
│   └── samples/
│       ├── hello-site.yaml          # Valid CR
│       └── bad-site.yaml            # Intentionally invalid CR (validation demo)
└── website-operator/        # Created by setup-lab.sh, gitignored — the kubebuilder project
```

## Prerequisites

- A Kubernetes cluster you have cluster-admin on. The 4-node Cilium cluster from [../k8s-setup-w-cilium/](../k8s-setup-w-cilium/) works fine; so does `kind`. The lab assumes whatever `kubectl` currently points at.
- `go` ≥ 1.23, `kubebuilder` ≥ v4.0 (lab tested against v4.14), `kubectl`, `make`. The basic lab flow (`make run`) does **not** need a container runtime — the controller runs as a normal Go process against your kubectl context. A container runtime is only needed if you later try `make docker-build` / `make deploy`.
- If you do want to build/deploy as an image: `docker`, `nerdctl`, or `podman` works. The cluster from this repo's [../registry-installation/](../registry-installation/) provides `nerdctl` on the control plane — invoke kubebuilder's image targets with `make docker-build CONTAINER_TOOL=nerdctl` (and similarly for `docker-push` / `deploy`).
- `prereq-check.sh` validates all of the above and confirms the user can create CRDs in the current cluster.

## Lazy path

Just want to see the operator work end-to-end?

```shell
cd controller-crds-operators
./prereq-check.sh                    # bail out early if tools / cluster aren't right
./setup-lab.sh                        # scaffolds website-operator/, installs CRD, applies hello-site
```

`setup-lab.sh` ends by telling you to start the controller in a second terminal:

```shell
cd controller-crds-operators/website-operator
make run                              # foreground; logs every reconcile to stdout
```

Back in the first terminal, watch the controller fill in the world:

```shell
kubectl get websites
# NAME         REPLICAS   READY   URL                                              AGE
# hello-site   3          3       http://hello-site.default.svc.cluster.local      30s

kubectl get deploy,svc,cm,pods -l app=hello-site
kubectl describe website hello-site
```

Confirm nginx is actually serving the HTML:

```shell
kubectl run curl --image=curlimages/curl -it --rm --restart=Never -- \
  curl http://hello-site.default.svc.cluster.local
```

When you're ready to see the cool parts (self-heal, validation rejection, cascading delete, …):

```shell
./demo-magic.sh                       # interactive, pauses between steps
./demo-magic.sh --no-pause            # CI / non-interactive
```

When you're done:

```shell
# Stop the controller in the other terminal (Ctrl-C), then:
./teardown-lab.sh                     # deletes CRs, CRD, scaffold dir
```

`setup-lab.sh` honours these env vars:

| Var | Default | Notes |
|---|---|---|
| `LAB_DIR` | `<repo>/controller-crds-operators/website-operator` | Where the kubebuilder project goes. Anywhere off-tree is fine. |
| `DOMAIN` | `example.com` | Becomes the API group suffix. **If you change this**, the import path `github.com/example/website-operator/api/v1` in `solution/website_controller.go` and the `+kubebuilder:rbac` group `web.example.com` will not match — also override `REPO` and edit those references. |
| `REPO` | `github.com/example/website-operator` | Go module path. Same caveat as above. |
| `OWNER` | `Student` | Goes into the boilerplate header of generated files. |

## Step-by-step path (the actual lab)

This is the long-form lab. Read [scenario.md](scenario.md) for the *why* behind each step; this section is the *what*.

### Step 1 — Scaffold the project

```shell
mkdir -p ~/labs/website-operator && cd ~/labs/website-operator

kubebuilder init \
  --domain example.com \
  --repo github.com/example/website-operator \
  --owner "Student"

kubebuilder create api \
  --group web \
  --version v1 \
  --kind Website \
  --resource --controller
```

Press `y` if asked whether to create the resource and controller.

You should now have:

```
website-operator/
├── api/v1/
│   ├── website_types.go        ← define spec/status here
│   └── zz_generated.deepcopy.go
├── cmd/main.go                  ← controller-manager entrypoint
├── config/                      ← CRDs, RBAC, kustomize manifests
├── internal/controller/
│   └── website_controller.go    ← reconcile logic goes here
├── Dockerfile
├── Makefile
└── go.mod
```

### Step 2 — Define the API

Replace `api/v1/website_types.go` with [solution/website_types.go](solution/website_types.go) (or hand-type it from scenario.md while reading the explanations).

What to look at while you're there:

- `WebsiteSpec` is *desired state* (user writes), `WebsiteStatus` is *observed state* (controller writes). Never cross those streams.
- `+kubebuilder:validation:*` markers become OpenAPI schema in the generated CRD — the apiserver enforces them at admission.
- `+kubebuilder:default=*` markers fill in defaults at admission too, before your reconcile ever sees the object.
- `+kubebuilder:subresource:status` splits `/status` from `/spec` so updating `.status.readyReplicas` doesn't bump the spec generation (and won't trigger an infinite reconcile loop).
- `+kubebuilder:printcolumn` markers are what `kubectl get websites` columns display.

### Step 3 — Implement Reconcile

Replace `internal/controller/website_controller.go` with [solution/website_controller.go](solution/website_controller.go).

The shape to internalise:

```
Reconcile(req):
  fetch CR — return early if NotFound (children clean up via owner refs)
  for each child object kind (CM, Deployment, Service):
    CreateOrUpdate(ctx, child, mutateFn):
      mutateFn sets all the spec fields from CR.Spec
      mutateFn calls SetControllerReference(CR, child, scheme)
  update CR.Status (.readyReplicas, .url, conditions)
  return Result{}, nil
```

Three things the code does that are doctrine, not detail:

- **`ctrl.CreateOrUpdate`** is what makes reconciliation *idempotent*. It Gets the object, runs your mutator, Creates if not present and Updates if it is. Calling Reconcile a hundred times in a row does not produce a hundred Deployments.
- **`ctrl.SetControllerReference`** stamps an OwnerReference on the child pointing back at the Website. That single line buys you cascading deletion and the `Owns(...)` watch wiring below.
- **`SetupWithManager` with `Owns(child)`** registers an event handler: when a child Deployment changes, the **owner Website** is enqueued for reconcile. This is why deleting the child Deployment causes immediate self-heal — the controller finds out, looks at the owner, sees the Deployment is gone, and recreates it.

### Step 4 — Generate, install, run

From inside the project:

```shell
make manifests       # rebuild config/crd/ from kubebuilder markers
make generate        # rebuild zz_generated.deepcopy.go
make install         # kubectl apply config/crd/bases/...
make run             # run controller-manager locally against your kubectl context
```

Why `make run` (not `make deploy`)?

For teaching, `make run` is unbeatable: the controller is a normal process attached to your terminal, you see every reconcile log immediately, and `Ctrl-C` + edit + re-run is the iteration loop. `make deploy` builds an image and runs the controller inside the cluster — useful later, but slower to iterate on.

### Step 5 — Apply a sample CR

In a second terminal:

```shell
kubectl apply -f - <<'EOF'
apiVersion: web.example.com/v1
kind: Website
metadata:
  name: hello-site
spec:
  replicas: 3
  html: |
    <!doctype html>
    <html><body>
      <h1>Hello from the Website operator!</h1>
    </body></html>
EOF
```

Then watch:

```shell
kubectl get websites
kubectl get deploy,svc,cm,pods -l app=hello-site
kubectl describe website hello-site
```

`kubectl describe website` is the best place to see your `Conditions` (Ready=True / Ready=False with reason).

### Step 6 — Demos

These five behaviours are the "operators are magic" payoff. Run them by hand or via [demo-magic.sh](demo-magic.sh).

#### Self-healing
```shell
kubectl delete deploy hello-site
# Within seconds the controller sees the Deployment go away (Owns watch),
# enqueues the Website, and CreateOrUpdate brings it back.
kubectl get deploy hello-site
```

#### Spec change triggers reconcile
```shell
kubectl patch website hello-site --type=merge -p '{"spec":{"replicas":5}}'
kubectl get pods -l app=hello-site -w
```

#### HTML update propagates
```shell
kubectl patch website hello-site --type=merge \
  -p '{"spec":{"html":"<h1>Updated content!</h1>"}}'
kubectl get cm hello-site -o jsonpath='{.data.index\.html}'
# Existing pods keep serving the OLD content until they restart — nginx doesn't
# reload mounted ConfigMap files automatically. That's a real-world gotcha
# students will hit with sidecar reloaders / `kubectl rollout restart`.
```

#### Validation rejection
```shell
kubectl apply -f solution/samples/bad-site.yaml
# Server rejects with a clear error — apiserver enforced the OpenAPI schema
# from the markers, your controller never even saw the request.
```

#### Cascading delete
```shell
kubectl delete website hello-site
kubectl get deploy,svc,cm -l app=hello-site
# Empty. The OwnerReferences from SetControllerReference + Kubernetes' garbage
# collector took care of cleanup with zero finalizer code on your part.
```

### Suggested student exercises

Easiest → hardest:

1. **Add a `title` field** to `WebsiteSpec` and inject it into the HTML.
2. **Add a print column** showing `.spec.image`.
3. **Add a finalizer** that logs a goodbye message before allowing deletion. (Forces students to handle the "object marked for deletion" branch in Reconcile.)
4. **Add an Ingress child** when `spec.host` is set — pairs nicely with [../ingress-nginx-w-certificate/](../ingress-nginx-w-certificate/).
5. **Watch a non-owned resource** — e.g. enqueue a Website when any Pod with `managed-by=website-operator` changes.
6. **Write a unit test** using the envtest scaffold under `internal/controller/` that `make test` already runs.
7. **Add a webhook** that rejects HTML containing `<script>` tags.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `kubebuilder: command not found` | Install per the kubebuilder quickstart, or use `go install sigs.k8s.io/kubebuilder/v4/cmd@latest`. |
| `make manifests` errors about missing `controller-gen` | `make` downloads it on first run; needs internet + Go. |
| `make install` says `couldn't connect to server` | Check `kubectl config current-context` — `make install` uses your current kubectl context, no flag for it. |
| `make run` panics with `failed to get scheme` | Usually a stale `zz_generated.*` after editing types — re-run `make generate`. |
| `kubectl apply` of a `Website` returns `no matches for kind "Website"` | CRD not installed — run `make install`. |
| Controller logs `forbidden: ... cannot create deployments` | RBAC markers weren't regenerated. Re-run `make manifests`. (Note: `make run` runs as **you** outside the cluster, not as the controller's ServiceAccount, so RBAC errors only show up in `make deploy` mode.) |
| The lab dir got wedged after a failed scaffold | `./teardown-lab.sh` deletes the dir; `./setup-lab.sh` will re-scaffold. The script wipes `${LAB_DIR}` on every run. |

## Why this example works pedagogically

| Concept | Where students see it |
|---|---|
| Spec vs Status separation | `WebsiteSpec` / `WebsiteStatus` |
| OpenAPI validation | `+kubebuilder:validation:*` markers; `bad-site.yaml` rejected |
| Reconcile loop | `Reconcile()` |
| Owner references | `ctrl.SetControllerReference` + cascading-delete demo |
| Idempotency | `CreateOrUpdate` runs cleanly on every reconcile |
| Watching children | `Owns(...)` + delete-deployment self-heal demo |
| Status conditions | `Ready` condition with `Progressing`/`AllReplicasReady` reasons |
| RBAC generation | `+kubebuilder:rbac` markers → `config/rbac/role.yaml` |
| Print columns | `kubectl get websites` showing custom columns |
