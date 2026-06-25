# syntax=docker/dockerfile:1

ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

LABEL org.opencontainers.image.title="ForwardMeasure Nominatim"
LABEL org.opencontainers.image.description="Nominatim image built from Ubuntu packages and Nominatim Python packages"

ARG NOMINATIM_VERSION=5.3.2

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/nominatim/venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      gosu \
      libicu-dev \
      libpq-dev \
      osmium-tool \
      osm2pgsql \
      postgresql-client \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 nominatim \
    && useradd --system --uid 10001 --gid nominatim --home-dir /nominatim --shell /usr/sbin/nologin nominatim \
    && mkdir -p /nominatim /usr/local/lib/forwardmeasure \
    && chown -R nominatim:nominatim /nominatim

RUN python3 -m venv /opt/nominatim/venv \
    && pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir \
      "nominatim-db==${NOMINATIM_VERSION}" \
      "nominatim-api==${NOMINATIM_VERSION}" \
      falcon \
      "gunicorn>=25,<26"

USER root

COPY scripts/nominatim-db-env.sh /usr/local/lib/forwardmeasure/nominatim-db-env.sh
COPY scripts/forwardmeasure-wait-for-postgres.sh /usr/local/bin/forwardmeasure-wait-for-postgres
COPY scripts/forwardmeasure-nominatim-api.sh /usr/local/bin/forwardmeasure-nominatim-api
COPY scripts/forwardmeasure-nominatim-import.sh /usr/local/bin/forwardmeasure-nominatim-import

RUN chmod 0755 \
      /usr/local/lib/forwardmeasure/nominatim-db-env.sh \
      /usr/local/bin/forwardmeasure-wait-for-postgres \
      /usr/local/bin/forwardmeasure-nominatim-api \
      /usr/local/bin/forwardmeasure-nominatim-import

ENV PROJECT_DIR=/nominatim
ENV NOMINATIM_HTTP_PORT=8080
ENV GUNICORN_WORKERS=2
ENV NOMINATIM_DATABASE_WEBUSER=nominatim
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

CMD ["/usr/local/bin/forwardmeasure-nominatim-api"]
