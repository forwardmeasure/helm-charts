# Apicurio Registry Deployment

This chart creates one `ApicurioRegistry3` custom resource for the separately
installed Apicurio Registry operator to reconcile. It also supplies the
restrictive application NetworkPolicy that replaces the operator's broad
default policy.

KafkaSQL journal, snapshot, and event topics are pre-created by the separate
topics release and topic auto-creation is disabled. Operator-managed ingress
and NetworkPolicies remain disabled so routing and ingress isolation can be
owned by the platform. This chart supplies restrictive policies for both the
application and UI; gateway access is limited to `access.gatewayNamespace`.

Set `auth.enabled=true` to enable backend OIDC validation and configure the
standalone UI for the same OIDC client. `cors.allowedOrigins` must explicitly
contain every browser origin that calls an API hosted on a different origin.
For a path-mounted UI, set `ui.contextPath`, `ui.apiUrl`, and the matching OIDC
redirect and logout URLs.

The rendered authentication block explicitly selects required TLS certificate
verification. Besides being the secure production setting, this works around
an Apicurio operator 3.3.0 null dereference when the `auth.tls` object is absent.

An explicit startup probe gates the operator's liveness and readiness probes
while KafkaSQL replays its journal and initializes the local state store.

Apicurio operator 3.3.0 records a disabled UI Deployment as active and leaves
the Registry Ready condition false. Until upstream releases a fix, this chart
keeps the UI component enabled with zero replicas when `ui.enabled` is false.
This creates no UI pods or ingress, but permits the operator's readiness model
to converge. Remove the workaround when upgrading to a fixed operator release.
