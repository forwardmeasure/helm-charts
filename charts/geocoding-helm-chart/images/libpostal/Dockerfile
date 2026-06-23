# syntax=docker/dockerfile:1

ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG GO_VERSION=1.21.0
ARG LIBPOSTAL_REPO=https://github.com/openvenues/libpostal.git
ARG LIBPOSTAL_REF=master
ARG LIBPOSTAL_DATADIR=/usr/local/share/libpostal
ARG LIBPOSTAL_MODEL=default
ARG WOF_LIBPOSTAL_REPO=https://github.com/whosonfirst/go-whosonfirst-libpostal.git
ARG WOF_LIBPOSTAL_REF=master

ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      autoconf \
      automake \
      build-essential \
      git \
      libtool \
      make \
      pkg-config \
      curl \
      wget \
    && rm -rf /var/lib/apt/lists/*

RUN wget -qO- "https://golang.org/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" | tar -C /usr/local -xzf -

ENV GOROOT=/usr/local/go
ENV GOPATH=/go
ENV PATH="${PATH}:${GOROOT}/bin:${GOPATH}/bin"

WORKDIR /code/libpostal
RUN git init . \
    && git remote add origin "${LIBPOSTAL_REPO}" \
    && git fetch --depth 1 origin "${LIBPOSTAL_REF}" \
    && git checkout FETCH_HEAD

RUN ./bootstrap.sh \
    && configure_flags="--datadir=${LIBPOSTAL_DATADIR}" \
    && if [ "${TARGETARCH}" = "arm64" ]; then configure_flags="${configure_flags} --disable-sse2"; fi \
    && if [ "${LIBPOSTAL_MODEL}" != "default" ]; then configure_flags="${configure_flags} MODEL=${LIBPOSTAL_MODEL}"; fi \
    && ./configure ${configure_flags} \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

WORKDIR /code/go-whosonfirst-libpostal
RUN git init . \
    && git remote add origin "${WOF_LIBPOSTAL_REPO}" \
    && git fetch --depth 1 origin "${WOF_LIBPOSTAL_REF}" \
    && git checkout FETCH_HEAD

RUN GO111MODULE=off make bin

FROM ubuntu:${UBUNTU_VERSION}

LABEL org.opencontainers.image.title="ForwardMeasure Libpostal Service"
LABEL org.opencontainers.image.description="Libpostal HTTP service built from openvenues/libpostal and go-whosonfirst-libpostal"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      libgomp1 \
      libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/share/libpostal/ /usr/local/share/libpostal/
COPY --from=builder /code/go-whosonfirst-libpostal/bin/wof-libpostal-server /usr/local/bin/wof-libpostal-server
COPY docker-entrypoint.sh /usr/local/bin/forwardmeasure-libpostal

RUN groupadd --system --gid 10002 libpostal \
    && useradd --system --uid 10002 --gid libpostal --home-dir /nonexistent --shell /usr/sbin/nologin libpostal \
    && chmod 0755 /usr/local/bin/wof-libpostal-server /usr/local/bin/forwardmeasure-libpostal \
    && ldconfig

USER libpostal

ENV LIBPOSTAL_HOST=0.0.0.0
ENV LIBPOSTAL_PORT=4400

EXPOSE 4400

ENTRYPOINT ["/usr/local/bin/forwardmeasure-libpostal"]
