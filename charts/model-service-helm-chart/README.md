# model-service

Runtime-neutral Helm chart for model-backed HTTP, gRPC, or TCP services.

It creates a standard Kubernetes Deployment, optional multi-port Service,
optional ServiceAccount, and optional HPA. It does not impose KServe, Knative,
Triton, or framework-specific application protocols.

Configure `ports` to expose one or more named protocols. Probe specifications
are native Kubernetes objects, so HTTP, gRPC, TCP, and exec probes are all
supported. External model caches attach through ordinary `volumes` and
`volumeMounts` values.
