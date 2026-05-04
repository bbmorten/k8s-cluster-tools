// website_types.go — drop-in replacement for api/v1/website_types.go
//
// This file defines the shape of the Website CRD. The kubebuilder markers
// (// +kubebuilder:...) drive code generation: validation, defaults, print
// columns, and the deepcopy methods all come out of `make manifests generate`.
package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WebsiteSpec is what the user wants. Controller reads, never writes.
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

	// Image lets the student override the nginx image.
	// +kubebuilder:default="nginx:alpine"
	Image string `json:"image,omitempty"`
}

// WebsiteStatus is the observed state. Controller writes; user only reads.
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
