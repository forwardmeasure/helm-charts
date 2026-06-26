# Livy Images

This directory contains the custom runtime image used by the Livy Helm chart.

## Images

- `livy-spark`: builds from an Apache Spark image and installs Apache Livy into `/opt/livy`.

The image also installs cloud storage connectors used by Spark submissions:

- GCS: `gs://...`
- S3-compatible storage through Hadoop S3A: `s3a://...`

Use `s3a://bucket/path` for AWS S3, Ceph RGW, and MinIO paths. Plain `s3://`
paths are not the recommended Hadoop/Spark scheme.

## Local Build

From this directory:

```sh
docker build -t docker.io/forwardmeasure/livy-spark:0.9.0-spark3.5.8 livy-spark
```

From the repository root:

```sh
docker build -t docker.io/forwardmeasure/livy-spark:0.9.0-spark3.5.8 charts/livy-helm-chart/images/livy-spark
```

## Push To Docker Hub

```sh
export IMAGE_REGISTRY="docker.io/forwardmeasure"
export IMAGE_TAG="0.9.0-spark3.5.8"

docker push "${IMAGE_REGISTRY}/livy-spark:${IMAGE_TAG}"
```

The Helm chart keeps the image repository configurable so deployment-specific repositories, such as GCP Artifact Registry, can be used.

## S3-Compatible Storage

AWS S3 works with the default S3A provider chain when the driver and executor
pods have AWS credentials available through their environment, mounted files, or
cloud identity integration.

For Ceph RGW or MinIO, set the S3 endpoint in the Helm values:

```yaml
spark:
  s3:
    enabled: true
    endpoint: http://minio.minio.svc:9000
    pathStyleAccess: true
    sslEnabled: false
```

Credentials can be provided from an existing Kubernetes Secret. The chart injects
the secret into the Livy server pod and configures Spark to inject the same
values into driver and executor pods.

```sh
kubectl -n livy create secret generic s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="<access-key>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<secret-key>"
```

```yaml
spark:
  s3:
    enabled: true
    endpoint: http://minio.minio.svc:9000
    pathStyleAccess: true
    sslEnabled: false
    credentials:
      existingSecret: s3-credentials
```

The chart can also create the Secret when explicitly enabled:

```yaml
spark:
  s3:
    enabled: true
    endpoint: http://minio.minio.svc:9000
    pathStyleAccess: true
    sslEnabled: false
    credentials:
      create: true
      name: s3-credentials
      accessKeyId: "<access-key>"
      secretAccessKey: "<secret-key>"
```

Using `create: true` stores the secret values in the rendered Helm manifests and
Helm release history. For GitOps repositories, prefer `existingSecret`.

When either `spark.s3.credentials.existingSecret` or
`spark.s3.credentials.create=true` is set and no explicit provider is
configured, the chart uses
`com.amazonaws.auth.EnvironmentVariableCredentialsProvider`.

For temporary AWS credentials, include `AWS_SESSION_TOKEN` and enable it:

```yaml
spark:
  s3:
    credentials:
      existingSecret: s3-credentials
      sessionToken:
        enabled: true
        key: AWS_SESSION_TOKEN
```
