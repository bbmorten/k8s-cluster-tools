// website_controller.go — drop-in replacement for
// internal/controller/website_controller.go
//
// The Reconcile loop is the heart of the operator. Read it top-to-bottom:
//   1. fetch the Website CR
//   2. ensure ConfigMap (HTML)
//   3. ensure Deployment (nginx pods, replicas, image)
//   4. ensure Service
//   5. update status (.readyReplicas, .url, Conditions)
//
// All child objects get an OwnerReference back to the Website, so deleting
// the Website cascades to its children automatically (no finalizer needed
// for cleanup in this simple case).
package controller

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
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

// RBAC markers — generate config/rbac/role.yaml on `make manifests`.
// +kubebuilder:rbac:groups=web.example.com,resources=websites,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=web.example.com,resources=websites/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=web.example.com,resources=websites/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=services;configmaps,verbs=get;list;watch;create;update;patch;delete

func (r *WebsiteReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var site webv1.Website
	if err := r.Get(ctx, req.NamespacedName, &site); err != nil {
		// NotFound = the Website was deleted. Children are GC'd via ownerRef.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	logger.Info("Reconciling Website", "replicas", site.Spec.Replicas)

	if err := r.reconcileConfigMap(ctx, &site); err != nil {
		return ctrl.Result{}, fmt.Errorf("configmap: %w", err)
	}

	deploy, err := r.reconcileDeployment(ctx, &site)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("deployment: %w", err)
	}

	if err := r.reconcileService(ctx, &site); err != nil {
		return ctrl.Result{}, fmt.Errorf("service: %w", err)
	}

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

	if err == nil {
		// Re-fetch so .Status.ReadyReplicas reflects the cluster's current view.
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
// Owns(...) means: when a child Deployment/Service/ConfigMap changes, the
// owner Website is enqueued — that's how `kubectl delete deploy ...` triggers
// an immediate self-heal.
func (r *WebsiteReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&webv1.Website{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&corev1.ConfigMap{}).
		Complete(r)
}
