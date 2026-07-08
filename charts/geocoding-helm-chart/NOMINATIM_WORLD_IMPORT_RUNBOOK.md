# Nominatim World Import Runbook

This runbook builds a Nominatim database from a planet PBF on a self-managed
Postgres/PostGIS host, exports the completed database, uploads the dump to GCS,
and restores it into Cloud SQL for PostgreSQL.

The intent is to avoid doing the expensive OSM import/build directly inside
Cloud SQL.

## Assumptions

- The build machine is a GCP VM or another Linux host with Docker.
- The build machine has enough disk for the PBF, Postgres data, flatnode file,
  and dump output.
- The target Cloud SQL instance already exists.
- The build and target PostgreSQL major versions match where possible.
- The ForwardMeasure Nominatim image is available:
  `docker.io/forwardmeasure/nominatim:0.0.1`.

For a planet import, use a large machine and fast disk. A practical starting
point is at least 24 vCPU, 128GB RAM, and 2TB+ SSD-equivalent storage for the
build host. Increase disk if you keep both the live database and a dump on the
same volume.

## Variables

Edit these first. Run this block locally before creating the VM, and run it
again on the build VM after SSHing in. Shell variables do not survive the SSH
hop.

```sh
export PROJECT_ID="data-fabric-397316"
export REGION="us-central1"
export ZONE="us-central1-a"

export BUILD_VM_NAME="nominatim-build"
export BUILD_DATA_DISK_NAME="nominatim-build-data"
export BUILD_MACHINE_TYPE="n2-highmem-32"
export BUILD_DISK_SIZE_GB="2500"

export GCS_BUCKET="datafabric-druid-data-fabric-397316"
export GCS_PBF_OBJECT="nominatim/pbf/planet-latest.osm.pbf"
export GCS_DUMP_PREFIX="nominatim/dumps/nominatim.dir"

export PBF_URL="https://download.openplanetdata.com/osm/planet/pbf/v1/planet-latest.osm.pbf"

export POSTGRES_CONTAINER="nominatim-postgres"
export POSTGRES_IMAGE="postgis/postgis:18-3.6"
export POSTGRES_CLIENT_IMAGE="postgres:18"
export NOMINATIM_IMAGE="docker.io/forwardmeasure/nominatim:0.0.1"

export PG_ADMIN_USER="postgres"
export PG_ADMIN_PASSWORD="replace-admin-password"
export NOMINATIM_DB="nominatim"
export NOMINATIM_USER="nominatim"
export NOMINATIM_PASSWORD="replace-nominatim-password"

# Use the attached data disk mount if you created one:
# export BUILD_ROOT="/mnt/nominatim"
#
# Or use your home directory if it has enough free space:
export BUILD_ROOT="/home/pnandavanam/nominatim"
export PBF_PATH="${BUILD_ROOT}/pbf/planet-latest.osm.pbf"
export PROJECT_DIR="${BUILD_ROOT}/project"
export FLATNODE_DIR="${BUILD_ROOT}/flatnode"
export DUMP_DIR="${BUILD_ROOT}/dump/nominatim.dir"

export CLOUDSQL_INSTANCE="replace-cloudsql-instance-name"
export CLOUDSQL_PRIVATE_IP="replace-cloudsql-private-ip"
export CLOUDSQL_PORT="5432"
```

## Optional: Create A GCP Build VM

Skip this section if you already have a suitable machine.

```sh
gcloud compute instances create "${BUILD_VM_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type="${BUILD_MACHINE_TYPE}" \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-ssd \
  --scopes=cloud-platform \
  --create-disk=name="${BUILD_DATA_DISK_NAME}",size="${BUILD_DISK_SIZE_GB}GB",type=pd-ssd,device-name=nominatim-data
```

SSH into it:

```sh
gcloud compute ssh "${BUILD_VM_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}"
```

Install Docker and basic tools if needed:

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release postgresql-client
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

Log out and back in so the Docker group takes effect.

Format and mount the data disk if it is new. Skip this step if you are using a
normal directory such as `/home/pnandavanam/nominatim` instead of an attached
data disk.

```sh
sudo mkfs.ext4 -F /dev/disk/by-id/google-nominatim-data
sudo mkdir -p "${BUILD_ROOT}"
sudo mount /dev/disk/by-id/google-nominatim-data "${BUILD_ROOT}"
sudo chown -R "$USER:$USER" "${BUILD_ROOT}"
```

Create working directories:

```sh
mkdir -p \
  "${BUILD_ROOT}/pbf" \
  "${PROJECT_DIR}" \
  "${FLATNODE_DIR}" \
  "${BUILD_ROOT}/postgresql" \
  "${BUILD_ROOT}/dump"
```

## Download The Planet PBF

Use `curl` unless you specifically need `rclone`.

```sh
curl -L \
  -C - \
  --fail \
  --retry 10 \
  --retry-delay 30 \
  -o "${PBF_PATH}" \
  "${PBF_URL}"
```

Check the file:

```sh
ls -lh "${PBF_PATH}"
```

Upload the PBF to GCS so Kubernetes/Helm can reuse it later:

```sh
gcloud storage cp \
  "${PBF_PATH}" \
  "gs://${GCS_BUCKET}/${GCS_PBF_OBJECT}"
```

If you prefer `rclone`, do not use `--multi-thread-cutoff 0`; that has caused
rclone panics with this HTTP source. A safer command is:

```sh
rclone copy \
  --disable-http2 \
  --http-url https://download.openplanetdata.com \
  :http:osm/planet/pbf/v1/planet-latest.osm.pbf \
  "${BUILD_ROOT}/pbf" \
  --multi-thread-streams 16 \
  --transfers 1 \
  --progress
```

## Start Postgres/PostGIS

```sh
docker network create nominatim-build
```

```sh
docker run -d \
  --name "${POSTGRES_CONTAINER}" \
  --network nominatim-build \
  -e POSTGRES_USER="${PG_ADMIN_USER}" \
  -e POSTGRES_PASSWORD="${PG_ADMIN_PASSWORD}" \
  -v "${BUILD_ROOT}/postgresql:/var/lib/postgresql" \
  "${POSTGRES_IMAGE}"
```

Postgres 18+ Docker images expect the mount at `/var/lib/postgresql`, not
`/var/lib/postgresql/data`.

Wait for Postgres:

```sh
until docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${PG_ADMIN_USER}" -d postgres; do
  sleep 5
done
```

Create the Nominatim import role. Do not pre-create the `nominatim` database
when using the normal create-mode import; Nominatim creates it.

```sh
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_ADMIN_USER}" -d postgres <<SQL
CREATE ROLE ${NOMINATIM_USER} LOGIN CREATEDB PASSWORD '${NOMINATIM_PASSWORD}';
SQL
```

If the role already exists, reset it instead:

```sh
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_ADMIN_USER}" -d postgres <<SQL
ALTER ROLE ${NOMINATIM_USER} WITH LOGIN CREATEDB PASSWORD '${NOMINATIM_PASSWORD}';
SQL
```

Optional but useful Postgres settings for the build container:

```sh
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_ADMIN_USER}" -d postgres <<'SQL'
ALTER SYSTEM SET maintenance_work_mem = '8GB';
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET checkpoint_completion_target = '0.9';
ALTER SYSTEM SET checkpoint_timeout = '1h';
ALTER SYSTEM SET max_wal_size = '64GB';
ALTER SYSTEM SET random_page_cost = '1.1';
SQL
```

Restart Postgres to apply settings:

```sh
docker restart "${POSTGRES_CONTAINER}"
```

```sh
until docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${PG_ADMIN_USER}" -d postgres; do
  sleep 5
done
```

## Import PBF Into Nominatim

Run the Nominatim import wrapper from the ForwardMeasure image.

```sh
docker run --rm \
  --name nominatim-import \
  --network nominatim-build \
  -e PGHOST="${POSTGRES_CONTAINER}" \
  -e PGPORT=5432 \
  -e PGDATABASE="${NOMINATIM_DB}" \
  -e PGUSER="${NOMINATIM_USER}" \
  -e PGPASSWORD="${NOMINATIM_PASSWORD}" \
  -e PGMAINTENANCEDATABASE=postgres \
  -e PROJECT_DIR=/nominatim \
  -e PBF_PATHS=/pbf/planet-latest.osm.pbf \
  -e THREADS=16 \
  -e PBF_CACHE_ENABLED=true \
  -e NOMINATIM_FLATNODE_FILE=/flatnode/flatnode.file \
  -e FREEZE=true \
  -e RUN_CHECK_DATABASE=true \
  -e ANALYZE=true \
  -v "${BUILD_ROOT}/pbf:/pbf" \
  -v "${PROJECT_DIR}:/nominatim" \
  -v "${FLATNODE_DIR}:/flatnode" \
  "${NOMINATIM_IMAGE}" \
  /usr/local/bin/forwardmeasure-nominatim-import
```

For Cloud SQL-style constrained users, the chart also supports continue mode,
but on the self-managed build host create mode is preferred because it lets
Nominatim create the database cleanly.

## Monitor Import Progress

Watch the import logs directly from the Docker command. In another shell, these
queries are useful.

```sh
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_ADMIN_USER}" -d "${NOMINATIM_DB}" <<'SQL'
SELECT pid,
       state,
       wait_event_type,
       wait_event,
       now() - query_start AS age,
       left(query, 300) AS query
FROM pg_stat_activity
WHERE datname = 'nominatim'
ORDER BY query_start;
SQL
```

```sh
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_ADMIN_USER}" -d "${NOMINATIM_DB}" <<'SQL'
SELECT now(),
       pg_size_pretty(pg_total_relation_size('place')) AS place_size,
       pg_size_pretty(pg_total_relation_size('placex')) AS placex_size,
       pg_size_pretty(pg_total_relation_size('search_name')) AS search_name_size;
SQL
```

```sh
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_ADMIN_USER}" -d "${NOMINATIM_DB}" <<'SQL'
SELECT relname,
       n_tup_ins,
       n_live_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE relname IN ('place', 'placex', 'search_name', 'planet_osm_nodes', 'planet_osm_ways', 'planet_osm_rels')
ORDER BY relname;
SQL
```

## Verify The Completed Database

Run Nominatim's database check:

```sh
docker run --rm \
  --network nominatim-build \
  -e PGHOST="${POSTGRES_CONTAINER}" \
  -e PGPORT=5432 \
  -e PGDATABASE="${NOMINATIM_DB}" \
  -e PGUSER="${NOMINATIM_USER}" \
  -e PGPASSWORD="${NOMINATIM_PASSWORD}" \
  -e PROJECT_DIR=/nominatim \
  -v "${PROJECT_DIR}:/nominatim" \
  "${NOMINATIM_IMAGE}" \
  nominatim admin --check-database
```

Optionally run the API locally:

```sh
docker run --rm \
  --name nominatim-api \
  --network nominatim-build \
  -p 8080:8080 \
  -e PGHOST="${POSTGRES_CONTAINER}" \
  -e PGPORT=5432 \
  -e PGDATABASE="${NOMINATIM_DB}" \
  -e PGUSER="${NOMINATIM_USER}" \
  -e PGPASSWORD="${NOMINATIM_PASSWORD}" \
  -e PROJECT_DIR=/nominatim \
  -v "${PROJECT_DIR}:/nominatim" \
  "${NOMINATIM_IMAGE}"
```

In another shell:

```sh
curl -sS 'http://127.0.0.1:8080/status'
curl -sS 'http://127.0.0.1:8080/search?q=New%20York%2C%20NY&format=json&limit=3'
curl -sS 'http://127.0.0.1:8080/reverse?lat=40.7128&lon=-74.0060&format=json'
```

Stop the API container when done:

```sh
docker stop nominatim-api
```

## Dump The Completed Database

Use directory format so restore can run in parallel.

```sh
rm -rf "${DUMP_DIR}"
mkdir -p "${DUMP_DIR}"
```

```sh
docker run --rm \
  --network nominatim-build \
  -e PGPASSWORD="${PG_ADMIN_PASSWORD}" \
  -v "${BUILD_ROOT}/dump:/dump" \
  "${POSTGRES_CLIENT_IMAGE}" \
  pg_dump \
    -h "${POSTGRES_CONTAINER}" \
    -p 5432 \
    -U "${PG_ADMIN_USER}" \
    -d "${NOMINATIM_DB}" \
    --format=directory \
    --jobs=16 \
    --no-owner \
    --no-acl \
    --file=/dump/nominatim.dir
```

Check size:

```sh
du -sh "${DUMP_DIR}"
```

Upload the dump directory to GCS:

```sh
gcloud storage rsync -r \
  "${DUMP_DIR}" \
  "gs://${GCS_BUCKET}/${GCS_DUMP_PREFIX}"
```

## Prepare Cloud SQL Target

Create the database if it does not already exist:

```sh
gcloud sql databases create "${NOMINATIM_DB}" \
  --instance="${CLOUDSQL_INSTANCE}" \
  --project="${PROJECT_ID}"
```

Create or reset the target user as needed:

```sh
gcloud sql users create "${NOMINATIM_USER}" \
  --instance="${CLOUDSQL_INSTANCE}" \
  --project="${PROJECT_ID}" \
  --password="${NOMINATIM_PASSWORD}"
```

Create required extensions using a Cloud SQL admin user from a VM with private
network access to Cloud SQL:

```sh
docker run --rm \
  --network host \
  -e PGPASSWORD="${PG_ADMIN_PASSWORD}" \
  "${POSTGRES_CLIENT_IMAGE}" \
  psql \
  -h "${CLOUDSQL_PRIVATE_IP}" \
  -p "${CLOUDSQL_PORT}" \
  -U "${PG_ADMIN_USER}" \
  -d "${NOMINATIM_DB}" <<SQL
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
GRANT USAGE, CREATE ON SCHEMA public TO ${NOMINATIM_USER};
SQL
```

## Restore To Cloud SQL

Download the dump directory onto a restore host with fast network access to
Cloud SQL:

```sh
rm -rf "${DUMP_DIR}"
mkdir -p "${DUMP_DIR}"
```

```sh
gcloud storage rsync -r \
  "gs://${GCS_BUCKET}/${GCS_DUMP_PREFIX}" \
  "${DUMP_DIR}"
```

Restore with parallel workers:

```sh
docker run --rm \
  --network host \
  -e PGPASSWORD="${NOMINATIM_PASSWORD}" \
  -v "${DUMP_DIR}:/dump/nominatim.dir:ro" \
  "${POSTGRES_CLIENT_IMAGE}" \
  pg_restore \
  --host="${CLOUDSQL_PRIVATE_IP}" \
  --port="${CLOUDSQL_PORT}" \
  --username="${NOMINATIM_USER}" \
  --dbname="${NOMINATIM_DB}" \
  --jobs=16 \
  --no-owner \
  --no-acl \
  --verbose \
  /dump/nominatim.dir
```

If ownership or extension commands fail during restore, confirm the dump was
created with `--no-owner --no-acl` and that the extensions already exist in the
target database.

If Docker host networking is not available on your platform, install the
matching PostgreSQL client tools on the restore host and run the `psql` and
`pg_restore` commands directly from the host instead.

## Deploy Helm Against The Restored Cloud SQL Database

When the Cloud SQL database is already restored, disable the import Job:

```yaml
postgres:
  enabled: false

database:
  createSecret: false
  credentialsSecret: nominatim-db-credentials

nominatim:
  import:
    enabled: false
  api:
    waitForImport: false
```

The `nominatim-db-credentials` Secret should contain:

```yaml
stringData:
  PGHOST: "127.0.0.1"
  PGPORT: "5432"
  PGDATABASE: nominatim
  PGUSER: nominatim
  PGPASSWORD: replace-nominatim-password
```

Use `PGHOST=127.0.0.1` when the chart uses the Cloud SQL Auth Proxy sidecar.
Use the private IP only when connecting directly without the proxy.

## Helm Import From GCS Instead Of Offline Restore

If you want Kubernetes to import from the PBF in GCS instead of restoring a
completed dump, use the chart's cloud storage support:

```yaml
nominatim:
  import:
    enabled: true
    cloudStorage:
      enabled: true
      provider: gcs
      uri: gs://datafabric-druid-data-fabric-397316/nominatim/pbf/planet-latest.osm.pbf
    pbfCache:
      enabled: true
      size: 900Gi
      storageClass: premium-rwo
      retain: true
```

This causes the import Job to copy the PBF from GCS into the PBF cache PVC once
and then import from the cached local file.
