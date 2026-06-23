# Geocoding Images

This directory contains the custom images used by the geocoding Helm chart.

## Images

- `nominatim`: builds from Ubuntu packages plus `nominatim-db`/`nominatim-api` Python packages, with stable ForwardMeasure entrypoints for API, import, and database waiting.
- `libpostal`: builds `openvenues/libpostal` and the Who's On First Libpostal HTTP service from source.

The images intentionally use Ubuntu base images rather than `mediagis/nominatim`, `pelias/libpostal-service`, or `pelias/libpostal_baseimage`.

## Local Build

```sh
docker build -t docker.io/forwardmeasure/nominatim:0.0.1 nominatim
docker build -t docker.io/forwardmeasure/libpostal-service:0.0.1 libpostal
```

From the repository root:

```sh
docker build -t docker.io/forwardmeasure/nominatim:0.0.1 charts/geocoding-helm-chart/images/nominatim
docker build -t docker.io/forwardmeasure/libpostal-service:0.0.1 charts/geocoding-helm-chart/images/libpostal
```

## Push To Docker Hub

```sh
export IMAGE_REGISTRY="docker.io/forwardmeasure"
export IMAGE_TAG="0.0.1"

docker push "${IMAGE_REGISTRY}/nominatim:${IMAGE_TAG}"
docker push "${IMAGE_REGISTRY}/libpostal-service:${IMAGE_TAG}"
```

The Helm chart uses this registry by default.

## GitHub Actions

The repo includes `.github/workflows/geocoding-images.yml` to build and push both images to Docker Hub.

Create these GitHub repository secrets:

```text
DOCKERHUB_USERNAME
DOCKERHUB_TOKEN
```

Use a Docker Hub access token, not your account password.

The workflow runs automatically on pushes to `main` that touch:

```text
.github/workflows/geocoding-images.yml
charts/geocoding-helm-chart/images/**
```

It can also be run manually with `workflow_dispatch`, where you can set `image_tag` and choose whether to also tag `latest`.

## Cloud Build

```sh
export IMAGE_REGISTRY="docker.io/forwardmeasure"
export IMAGE_TAG="0.0.1"

gcloud builds submit charts/geocoding-helm-chart/images \
  --config charts/geocoding-helm-chart/images/cloudbuild.yaml \
  --substitutions=_REGISTRY="${IMAGE_REGISTRY}",_TAG="${IMAGE_TAG}"
```

Cloud Build must have Docker Hub push credentials configured if `_REGISTRY` is `docker.io/forwardmeasure`.

For GCP Artifact Registry instead:

```sh
export PROJECT_ID="my-project"
export REGION="us-central1"
export REPOSITORY="geocoding"
export IMAGE_REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"
export IMAGE_TAG="0.0.1"

gcloud artifacts repositories create "${REPOSITORY}" \
  --repository-format=docker \
  --location="${REGION}" || true

gcloud builds submit charts/geocoding-helm-chart/images \
  --config charts/geocoding-helm-chart/images/cloudbuild.yaml \
  --substitutions=_REGISTRY="${IMAGE_REGISTRY}",_TAG="${IMAGE_TAG}"
```

Then deploy with overrides:

```sh
helm upgrade --install geocoding ./charts/geocoding-helm-chart/helm-chart-sources \
  --set nominatim.image.repository="${IMAGE_REGISTRY}/nominatim" \
  --set nominatim.image.tag="${IMAGE_TAG}" \
  --set libpostal.image.repository="${IMAGE_REGISTRY}/libpostal-service" \
  --set libpostal.image.tag="${IMAGE_TAG}"
```

## Build Notes

The Nominatim image installs `nominatim-db` and `nominatim-api` from Python packages, plus OS-level runtime dependencies such as `osm2pgsql` and `postgresql-client`.

The Libpostal build is intentionally heavy because it compiles `openvenues/libpostal`, downloads/installs Libpostal model data into the image, then builds `go-whosonfirst-libpostal`. For reproducible production builds, pin `LIBPOSTAL_REF`, `WOF_LIBPOSTAL_REF`, and the Ubuntu base image to tags or digests.
