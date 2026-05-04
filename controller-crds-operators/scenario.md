Great idea for a teaching example. Let me build you a complete, runnable operator with a CRD and controller — something simple enough to grasp in one sitting but real enough to demonstrate every important concept.

## The example: `Website` operator

**What it does:** A user creates a `Website` custom resource specifying some HTML content and a number of replicas. The controller automatically creates a Deployment (with nginx serving that HTML) and a Service to expose it.

This is perfect pedagogically because:
- It's concrete and visible — students can `curl` the result
- Every reconcile concept appears (spec, status, owner refs, child resources, updates, deletion)
- It builds on Deployment/Service which they already know
- Students can extend it (add Ingress, TLS, custom domains, etc.)

Let me check the latest kubebuilder for the scaffolding commands and then build the full example.Good — kubebuilder v4.13 is current. Now let me build the full lab. I'll structure it as a hands-on lab guide with everything students need.

## Lab: Build a `Website` Operator

### Prerequisites

```bash
# Tools (versions verified for kubebuilder v4.13)
go version            # 1.23+
kubebuilder version   # v4.13+
kubectl version
docker --version

# A local cluster — kind works great for this
kind create cluster --name operator-lab
```

### Step 1: Scaffold the project

```bash
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

Press `y` when prompted to create both the resource and the controller.

After this, your directory has:

```
website-operator/
├── api/v1/
│   ├── website_types.go        ← define spec/status here
│   └── zz_generated.deepcopy.go
├── cmd/main.go                  ← controller-manager entrypoint
├── config/                      ← all the YAML (CRDs, RBAC, kustomize)
│   ├── crd/
│   ├── rbac/
│   └── samples/
├── internal/controller/
│   └── website_controller.go    ← reconcile logic goes here
├── Dockerfile
├── Makefile
└── go.mod
```

### Step 2: Define the API (the CRD shape)

Replace the contents of `api/v1/website_types.go` with this. The student-facing comments explain what each field does.

```go
// api/v1/website_types.go
package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WebsiteSpec defines what the user wants.
// The controller reads this; never writes to it.
type WebsiteSpec struct {
	// HTML content to serve. Required.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	HTML string `json:"html"`

	// Replicas is the number of nginx pods to run.
	// +kubebuilder:default=2
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	Replicas int32 `json:"replicas,omitempty"`

	// Image lets the student override the nginx image (default nginx:alpine).
	// +kubebuilder:default="nginx:alpine"
	Image string `json:"image,omitempty"`
}

// WebsiteStatus defines the observed state.
// The controller writes this; the user only reads it.
type WebsiteStatus struct {
	// ReadyReplicas is how many pods are currently ready.
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// URL is the in-cluster Service URL for this Website.
	URL string `json:"url,omitempty"`

	// Conditions reports the latest state transitions.
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Replicas",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="URL",type=string,JSONPath=`.status.url`
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=`.metadata.creationTimestamp`

// Website is the Schema for the websites API.
type Website struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebsiteSpec   `json:"spec,omitempty"`
	Status WebsiteStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type WebsiteList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Website `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Website{}, &WebsiteList{})
}
```

**Teaching points to highlight here:**
- `+kubebuilder:` markers generate validation, defaults, and CRD print columns
- `subresource:status` means the controller can update status without bumping the spec
- `printcolumn` defines what `kubectl get websites` shows

### Step 3: Implement the reconcile loop

Replace `internal/controller/website_controller.go`:

```go
// internal/controller/website_controller.go
package controller

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	webv1 "github.com/example/website-operator/api/v1"
)

type WebsiteReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// RBAC markers — these generate config/rbac/role.yaml
// +kubebuilder:rbac:groups=web.example.com,resources=websites,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=web.example.com,resources=websites/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=web.example.com,resources=websites/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=services;configmaps,verbs=get;list;watch;create;update;patch;delete

func (r *WebsiteReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Fetch the Website CR
	var site webv1.Website
	if err := r.Get(ctx, req.NamespacedName, &site); err != nil {
		// If not found, it was deleted — nothing to do (children are GC'd by ownerRef)
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	logger.Info("Reconciling Website", "replicas", site.Spec.Replicas)

	// 2. Reconcile the ConfigMap (holds the HTML)
	if err := r.reconcileConfigMap(ctx, &site); err != nil {
		return ctrl.Result{}, fmt.Errorf("configmap: %w", err)
	}

	// 3. Reconcile the Deployment
	deploy, err := r.reconcileDeployment(ctx, &site)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("deployment: %w", err)
	}

	// 4. Reconcile the Service
	if err := r.reconcileService(ctx, &site); err != nil {
		return ctrl.Result{}, fmt.Errorf("service: %w", err)
	}

	// 5. Update status
	site.Status.ReadyReplicas = deploy.Status.ReadyReplicas
	site.Status.URL = fmt.Sprintf("http://%s.%s.svc.cluster.local", site.Name, site.Namespace)

	condition := metav1.Condition{
		Type:    "Ready",
		Status:  metav1.ConditionFalse,
		Reason:  "Progressing",
		Message: fmt.Sprintf("%d/%d replicas ready", deploy.Status.ReadyReplicas, site.Spec.Replicas),
	}
	if deploy.Status.ReadyReplicas == site.Spec.Replicas {
		condition.Status = metav1.ConditionTrue
		condition.Reason = "AllReplicasReady"
	}
	meta.SetStatusCondition(&site.Status.Conditions, condition)

	if err := r.Status().Update(ctx, &site); err != nil {
		return ctrl.Result{}, fmt.Errorf("status update: %w", err)
	}

	return ctrl.Result{}, nil
}

func (r *WebsiteReconciler) reconcileConfigMap(ctx context.Context, site *webv1.Website) error {
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      site.Name,
			Namespace: site.Namespace,
		},
	}

	op, err := ctrl.CreateOrUpdate(ctx, r.Client, cm, func() error {
		cm.Data = map[string]string{"index.html": site.Spec.HTML}
		return ctrl.SetControllerReference(site, cm, r.Scheme)
	})
	if err == nil {
		log.FromContext(ctx).Info("ConfigMap reconciled", "op", op)
	}
	return err
}

func (r *WebsiteReconciler) reconcileDeployment(ctx context.Context, site *webv1.Website) (*appsv1.Deployment, error) {
	labels := map[string]string{"app": site.Name, "managed-by": "website-operator"}

	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      site.Name,
			Namespace: site.Namespace,
		},
	}

	_, err := ctrl.CreateOrUpdate(ctx, r.Client, deploy, func() error {
		deploy.Spec.Replicas = &site.Spec.Replicas
		deploy.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
		deploy.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{Labels: labels},
			Spec: corev1.PodSpec{
				Containers: []corev1.Container{{
					Name:  "nginx",
					Image: site.Spec.Image,
					Ports: []corev1.ContainerPort{{ContainerPort: 80}},
					VolumeMounts: []corev1.VolumeMount{{
						Name:      "html",
						MountPath: "/usr/share/nginx/html",
					}},
				}},
				Volumes: []corev1.Volume{{
					Name: "html",
					VolumeSource: corev1.VolumeSource{
						ConfigMap: &corev1.ConfigMapVolumeSource{
							LocalObjectReference: corev1.LocalObjectReference{Name: site.Name},
						},
					},
				}},
			},
		}
		return ctrl.SetControllerReference(site, deploy, r.Scheme)
	})

	// Re-fetch to get up-to-date status
	if err == nil {
		_ = r.Get(ctx, client.ObjectKeyFromObject(deploy), deploy)
	}
	return deploy, err
}

func (r *WebsiteReconciler) reconcileService(ctx context.Context, site *webv1.Website) error {
	labels := map[string]string{"app": site.Name}

	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      site.Name,
			Namespace: site.Namespace,
		},
	}

	_, err := ctrl.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = labels
		svc.Spec.Ports = []corev1.ServicePort{{
			Port:       80,
			TargetPort: intstr.FromInt(80),
			Protocol:   corev1.ProtocolTCP,
		}}
		return ctrl.SetControllerReference(site, svc, r.Scheme)
	})
	return err
}

// SetupWithManager wires up the watches.
// Owns(...) means: when a child Deployment/Service/ConfigMap changes,
// reconcile its owner Website.
func (r *WebsiteReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&webv1.Website{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&corev1.ConfigMap{}).
		Complete(r)
}
```

You'll also need to add this import line (controller-runtime needs it):

```go
import "k8s.io/apimachinery/pkg/runtime"
```

### Step 4: Generate, install, and run

```bash
# Generate CRDs and RBAC from the markers
make manifests
make generate

# Install the CRD into your cluster
make install

# Run the controller locally against your kind cluster
# (great for teaching — students see logs in their terminal, can hit save and re-run)
make run
```

In another terminal, create a sample Website:

```bash
cat <<EOF | kubectl apply -f -
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
      <p>This page is managed by a custom controller.</p>
    </body></html>
EOF
```

Now watch the magic:

```bash
kubectl get websites
# NAME         REPLICAS   READY   URL                                              AGE
# hello-site   3          3       http://hello-site.default.svc.cluster.local      30s

kubectl get deploy,svc,cm,pods -l app=hello-site
kubectl describe website hello-site
```

Test it:

```bash
kubectl run curl --image=curlimages/curl -it --rm --restart=Never -- \
  curl http://hello-site.default.svc.cluster.local
```

### Step 5: Demonstrate the magic for students

These are the "wow" moments to walk students through:

**Self-healing — delete a child, watch it come back:**
```bash
kubectl delete deploy hello-site
kubectl get deploy hello-site   # the controller recreates it within seconds
```

**Spec change triggers reconcile:**
```bash
kubectl patch website hello-site --type=merge -p '{"spec":{"replicas":5}}'
kubectl get pods -l app=hello-site -w
```

**HTML update propagates:**
```bash
kubectl patch website hello-site --type=merge \
  -p '{"spec":{"html":"<h1>Updated content!</h1>"}}'
# ConfigMap is updated; new pods will see new content (existing pods need restart for nginx to reload)
```

**Cascading deletion via owner references:**
```bash
kubectl delete website hello-site
kubectl get deploy,svc,cm -l app=hello-site   # all gone, no manual cleanup
```

**Validation rejects bad input:**
```bash
kubectl apply -f - <<EOF
apiVersion: web.example.com/v1
kind: Website
metadata:
  name: bad-site
spec:
  replicas: 99   # exceeds Maximum=10
  html: ""       # violates MinLength=1
EOF
# Server rejects with a clear validation error
```

### Suggested student exercises

Order from easiest to hardest:

1. **Add a new spec field** `title` and inject it into the HTML
2. **Add a print column** showing the image being used
3. **Add a finalizer** that logs a "goodbye" message before allowing deletion
4. **Add an Ingress child resource** when `spec.host` is set
5. **Watch a non-owned resource** — e.g. trigger reconcile when any Pod with a specific label changes
6. **Write a unit test** using `envtest` (the `make test` target already scaffolds this)
7. **Add a webhook** for advanced validation (e.g. reject HTML containing `<script>` tags)

### Why this example works for teaching

Every concept from the previous theory message has a concrete touchpoint here:

| Concept | Where students see it |
|---|---|
| Spec vs Status separation | `WebsiteSpec` / `WebsiteStatus` structs |
| OpenAPI validation | `+kubebuilder:validation:` markers; rejected `bad-site` |
| Reconcile loop | The `Reconcile` function |
| Owner references | `ctrl.SetControllerReference` + cascading delete demo |
| Idempotency | `CreateOrUpdate` runs cleanly on every reconcile |
| Watching children | `Owns(...)` + delete-deployment self-heal demo |
| Status conditions | The `Ready` condition with reasons |
| RBAC generation | `+kubebuilder:rbac:` markers → `config/rbac/role.yaml` |
| Print columns | `kubectl get websites` showing custom columns |

Want me to package this as a downloadable lab guide (`.md` file) with a complete solutions branch as a separate file? I can also add a step-by-step troubleshooting cheat sheet for the common issues students hit (RBAC errors, generated code stale, kind image-load gotchas).