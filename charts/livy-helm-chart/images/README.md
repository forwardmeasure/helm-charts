# Livy Images

This directory contains the custom runtime image used by the Livy Helm chart.

## Images

- `livy-spark`: builds from an Apache Spark image and installs Apache Livy into `/opt/livy`.

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
