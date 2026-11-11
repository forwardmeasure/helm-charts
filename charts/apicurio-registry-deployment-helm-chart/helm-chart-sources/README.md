# Apicurio Registry Deployment

This chart creates one `ApicurioRegistry3` custom resource for the separately
installed Apicurio Registry operator to reconcile. It also supplies the
restrictive application NetworkPolicy that replaces the operator's broad
default policy.

KafkaSQL journal, snapshot, and event topics are pre-created by the separate
topics release and topic auto-creation is disabled. Operator-managed ingress
and NetworkPolicies remain disabled. The registry is reachable only inside the
cluster: its NetworkPolicy admits port 8080 from its own namespace,
`access.applicationNamespace`, and `access.additionalApplicationNamespaces`,
and nothing else. It has no public route and no UI.

## Authentication and authorization

Both are always on; there is no setting to turn either off. `auth.clientId`
(the OIDC client the registry validates tokens for) and `auth.serverUrl`
(`https://<host>/realms/<realm>`) are required. Anonymous reads are off.

Role-based authorization (`apicurio.auth.role-based-authorization`) takes each
caller's roles from its token (`apicurio.auth.role-source=token`):

| Role | Grants |
| --- | --- |
| `sr-readonly` | Read every group, artifact, and version |
| `sr-developer` | Read, and create or update artifacts and versions |
| `sr-admin` | Everything, including global rules and configuration |

Apicurio Registry 3.3.3 checks these with Quarkus's `SecurityIdentity.hasRole`.
For a Keycloak token without a `groups` claim, Quarkus OIDC reads the realm
roles in `realm_access.roles` and the client roles in
`resource_access.<auth.clientId>.roles`. Owner-only authorization and
authenticated read access stay off, so a signed-in caller holding none of the
three roles can read nothing.

The rendered authentication block explicitly selects required TLS certificate
verification. Besides being the secure production setting, this works around
an Apicurio operator 3.3.0 null dereference when the `auth.tls` object is absent.

An explicit startup probe gates the operator's liveness and readiness probes
while KafkaSQL replays its journal and initializes the local state store.

## No UI

Apicurio operator 3.3.0 records a disabled UI Deployment as active and leaves
the Registry Ready condition false; its readiness code is unchanged in 3.3.3.
The chart therefore keeps the UI component enabled at zero replicas, with its
ingress, NetworkPolicy, and PodDisruptionBudget off. No UI pod runs and nothing
routes to it. Remove the workaround when upgrading to a fixed operator release.
