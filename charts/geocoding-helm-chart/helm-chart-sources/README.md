# Geocoding Helm Chart

Deploys optional components for a geocoding stack:

- PostGIS/Postgres StatefulSet
- Nominatim import Job
- Nominatim API Deployment
- Libpostal HTTP Deployment

All three major components can be enabled or disabled independently.

## Default Install

The default values deploy PostGIS, import the Monaco OpenStreetMap extract, start the Nominatim API, and start Libpostal.

```sh
helm install geocoding ./charts/geocoding-helm-chart/helm-chart-sources
```

## External Postgres/PostGIS

Create or reuse a Kubernetes Secret with:

```yaml
stringData:
  PGHOST: postgres.example.internal
  PGPORT: "5432"
  PGDATABASE: nominatim
  PGUSER: nominatim
  PGPASSWORD: replace-me
```

Then install with:

```yaml
postgres:
  enabled: false

database:
  createSecret: false
  credentialsSecret: nominatim-db-credentials
```

The external PostgreSQL server must have PostGIS and hstore available. Choose
the import mode based on how the target database is managed:

- `nominatim.import.mode: create` runs the normal Nominatim import. The target
  `database.name` must not already exist because `nominatim import` creates it.
  `PGUSER` needs enough privilege to create the database and required
  extensions.
- `nominatim.import.mode: continue` skips database creation and runs
  `nominatim import --continue import-from-file`. Use this when Terraform or a
  DBA creates the target database and the import user cannot create databases.

For `mode: continue`, the target database must already contain the required
extensions and the import user must be able to create objects in `public`:

```sql
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
GRANT USAGE, CREATE ON SCHEMA public TO nominatim;
```

On Cloud SQL for PostgreSQL, extension creation must be done by a user in the
`cloudsqlsuperuser` role, such as the default `postgres` user.

Then configure:

```yaml
nominatim:
  import:
    mode: continue
    continueStep: import-from-file
```

For production, prefer managing the database credentials Secret outside the
chart.

By default, `nominatim.database.webUser` is `nominatim`, matching `database.username`. If you want a restricted query role, create that role in Postgres, make its credentials available to Nominatim, and set `nominatim.database.webUser`.

## Generated Secret From Environment Variables

This is useful for local/dev bootstrap, but it is not the preferred production path. Helm values, rendered manifests, shell history, CI logs, and Helm release metadata can all expose these values.

Helm does not read shell environment variables on its own. Pass them into chart values at install time and the chart will render them into the generated Kubernetes Secret:

```sh
export NOMINATIM_DB_PASSWORD="replace-me"
export NOMINATIM_DB_NAME="nominatim"
export NOMINATIM_DB_USER="nominatim"

helm upgrade --install geocoding ./charts/geocoding-helm-chart/helm-chart-sources \
  --namespace geocoding \
  --create-namespace \
  --set-string database.name="${NOMINATIM_DB_NAME}" \
  --set-string database.username="${NOMINATIM_DB_USER}" \
  --set-string database.password="${NOMINATIM_DB_PASSWORD}"
```

Additional generated Secret keys can be supplied through `database.extraSecretStringData`:

```sh
helm upgrade --install geocoding ./charts/geocoding-helm-chart/helm-chart-sources \
  --set-string database.extraSecretStringData.MY_ENV_VAR="${MY_ENV_VAR}"
```

For production, prefer a pre-existing Secret or an External Secrets controller backed by GCP Secret Manager:

```yaml
database:
  createSecret: false
  credentialsSecret: nominatim-db-credentials
```

The Secret should already exist in the release namespace and contain `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD`.

## GCP Cloud SQL

For GKE with Cloud SQL, disable the in-chart Postgres instance and enable the Cloud SQL Auth Proxy. The chart renders the proxy as a native Kubernetes sidecar init container for both the Nominatim API Deployment and the Nominatim import Job.

```yaml
postgres:
  enabled: false

serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: nominatim@my-project.iam.gserviceaccount.com

cloudSqlProxy:
  enabled: true
  instanceConnectionName: my-project:us-central1:nominatim
  privateIp: true

database:
  createSecret: true
  name: nominatim
  username: nominatim
  password: replace-me
```

When `cloudSqlProxy.enabled=true`, the generated database Secret defaults `PGHOST` to `127.0.0.1` and `PGPORT` to `cloudSqlProxy.port`.

For production, prefer keeping `cloudSqlProxy.enabled=true` but setting `database.createSecret=false`, then populate `database.credentialsSecret` from GCP Secret Manager through External Secrets.

If you use an existing database Secret with Cloud SQL Proxy, set:

```yaml
database:
  createSecret: false
  credentialsSecret: nominatim-db-credentials
```

That existing Secret must use the proxy endpoint:

```yaml
stringData:
  PGHOST: "127.0.0.1"
  PGPORT: "5432"
  PGDATABASE: nominatim
  PGUSER: nominatim
  PGPASSWORD: replace-me
```

If Workload Identity is not available, mount a service account JSON key for the proxy:

```yaml
cloudSqlProxy:
  enabled: true
  instanceConnectionName: my-project:us-central1:nominatim
  credentialsSecret: cloudsql-proxy-credentials
  credentialsKey: service_account.json
```

`cloudSqlProxy.instanceConnectionNameSecret` can be used instead of `instanceConnectionName` if you want to source the instance connection name from a Kubernetes Secret.

## Image Strategy

The chart defaults to ForwardMeasure-owned images:

- `docker.io/forwardmeasure/nominatim:0.0.1`
- `docker.io/forwardmeasure/libpostal-service:0.0.1`

The source for those images lives in `charts/geocoding-helm-chart/images`. They are built from Ubuntu base images and upstream source/package repositories, not from `mediagis/nominatim`, `pelias/libpostal-service`, or `pelias/libpostal_baseimage`.

If you mirror the images to GCP Artifact Registry, override the repositories:

```yaml
nominatim:
  image:
    repository: us-central1-docker.pkg.dev/my-project/geocoding/nominatim
    tag: "0.0.1"

libpostal:
  image:
    repository: us-central1-docker.pkg.dev/my-project/geocoding/libpostal-service
    tag: "0.0.1"
```

## Disable Components

```yaml
postgres:
  enabled: false

nominatim:
  enabled: false

libpostal:
  enabled: false
```

You can also keep Nominatim enabled but disable the import Job when the database has already been imported:

```yaml
nominatim:
  import:
    enabled: false
  api:
    waitForImport: false
```

## Nominatim Data

Use `nominatim.import.pbfUrls` for one or more downloadable OpenStreetMap
extracts, or `nominatim.import.pbfPaths` for one or more mounted files. The
singular `nominatim.import.pbfUrl` and `nominatim.import.pbfPath` values are
intentionally unsupported. If you use `pbfPaths`, mount the data through
`nominatim.import.extraVolumes` and `nominatim.import.extraVolumeMounts`.

For larger imports, enable a durable PBF cache before the first run. The import
Job writes downloaded extracts to `<mountPath>/extracts` and writes merged output
to `<mountPath>/merged.osm.pbf`. Completed files get `.complete` markers so a
new Job can reuse them after a failed import:

```yaml
nominatim:
  import:
    pbfCache:
      enabled: true
      size: 100Gi
      storageClass: premium-rwo
      retain: true
```

When `pbfCache.enabled=true`, downloaded and merged PBF files are preserved even
if `cleanupDownloadedPbf=true`. Set `pbfCache.existingClaim` to use a PVC that is
managed outside this chart. For chart-created cache PVCs, `retain: true` adds
`helm.sh/resource-policy: keep` so the cache can survive `helm uninstall`.

For larger imports, increase Postgres storage/resources, lower import threads if
the database is I/O bound, increase Nominatim import resources, and consider
enabling `nominatim.flatnode`.

The import Job defaults to `restartPolicy: Never` and `backoffLimit: 0` so a
failed import keeps one failed pod with useful logs. Avoid automatic retries for
imports: a failed run may leave partial database objects behind and should be
cleaned up before rerunning.

The API Deployment waits for the import Job to finish before starting. The
waiter checks `nominatim_properties.database_version`, which Nominatim writes at
the end of import. Earlier tables such as `placex` appear before tokenizer setup
has completed and are not a safe readiness marker.
