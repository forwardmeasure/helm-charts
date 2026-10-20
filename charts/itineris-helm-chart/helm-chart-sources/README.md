<!--
    Licensed to the Apache Software Foundation (ASF) under one or more
    contributor license agreements. See the NOTICE file distributed with
    this work for additional information regarding copyright ownership.
    The ASF licenses this file to You under the Apache License, Version 2.0
    (the "License"); you may not use this file except in compliance with
    the License. You may obtain a copy of the License at

        https://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
-->

# Itineris 2.0 deployment

This chart deploys the combined Gremlin, tenant/graph administration and analytics API on port
8182. PostgreSQL, Cassandra, OpenSearch, Keycloak/AuthZEN and their Secrets must already exist.

The pre-install/pre-upgrade migration hook uses `controlPlane.migrations.ownerSecret`. The
application receives only `controlPlane.database.runtimeSecret`. Both database roles must exist;
the migration command applies Liquibase changes and grants runtime DML/sequence access to the
three Itineris tables, without granting schema ownership or CREATE. Hook failure blocks the
release. When an external migration pipeline owns this, disable the hook only after applying the
same migrations/grants successfully.

Build the server, migrations and Spark runner images from the integration checkout. Configure
`image`, `controlPlane.migrations.image` and `analyticsJob.image` with those image references,
preferably digests. The latter image is used by API-submitted workers and the optional explicit
one-shot Job. Local review images have been built; no image has been published. The Itineris
operations notes record their exact IDs. Use registry manifest digests after publication; a local
Docker image ID is not a registry manifest digest.

Configure `itineris.keycloakIssuer`, `itineris.tokenAudience`, `itineris.clientId`,
`itineris.organizationClientId`, `itineris.clientSecret` and `itineris.tenantDomain`. Token audiences
and Organization role grants are configured in Keycloak; this chart does not invent identities
or AuthZEN permissions.

The server's namespace Role can create/read/update/suspend batch Jobs and read/delete pods. It cannot
read Secret values through the Kubernetes API. Workers have a different service account with
pod/service/configmap permissions required by distributed Spark. Both Roles are namespace-scoped.
If a deployment centrally manages RBAC, set `analytics.rbac.create=false` and provision the same
permissions. Set the worker account name through `analytics.serviceAccount.name`.

API-submitted jobs use `analytics.master` (default `local[2]`), `analytics.deadline`,
`analytics.resources` and `analytics.sparkConfigurationProperties`. Distributed mode uses
`k8s://https://kubernetes.default.svc`; the driver name/address is projected from the Downward
API and the same image starts executor pods. Backend passwords are forwarded as Secret references.
Completed Pods are removed after `analytics.podRetention`, checked at
`analytics.retentionInterval`; completed/suspended Job identities remain reserved recovery fences.

`analyticsJob.image.pullPolicy` reaches API and direct driver Pods and their Spark executors.
`imagePullSecrets` reaches both drivers and executors. If the application is run without this
chart and no policy is configured, Kubernetes retains its normal image-pull defaults.

`cql.hosts` supports host[:port], with `cql.port` as the fallback for provisioning and graph reads.
The default hostname has no embedded port, so changing `cql.port` takes effect. IPv6 endpoints
accept bare addresses or bracketed addresses with an explicit port. Supply
replication strategy and datacenter replication appropriate to the actual Cassandra cluster.
`opensearch.endpoints` contains full URLs for admin operations; `opensearch.hosts` configures
graph reads/writes, with `opensearch.port` as the fallback graph port. Endpoints containing a port
retain that explicit port. Both settings must identify the same backend; full admin URLs keep
their own scheme/port. Configure certificate Secret names,
store filenames and password keys under `cql.ssl` and `opensearch.ssl`. The server, admin clients,
worker drivers and Spark executors now receive the same certificate policy and read-only files.
Client authentication requires TLS enabled and a Secret; its store and private-key password keys
may differ. Set `keyPasswordKey` equal to `keystorePasswordKey` when the passwords are identical.

The optional `analyticsJob.enabled` manifest is an operator-supplied direct run. Its inputs include
physical storage identity and it does not create a durable API run record. Prefer the authenticated
analytics API for ordinary tenant requests. Use a distinct lowercase DNS-label `analyticsJob.name`
for each direct run: Job templates are immutable. The reserved migrations suffix cannot be reused
while migrations are enabled. Long names retain their distinguishing suffix instead of truncating
both Jobs to the same name.

Server pods carry `app.kubernetes.io/component=server`; the Service selects that component so
Spark worker pods never become HTTP endpoints. The existing Deployment selector remains stable
for upgrades.

The templates pass Helm lint and rendering checks for local and distributed settings. No chart
was installed, no image was started and no tests were executed for these changes.
