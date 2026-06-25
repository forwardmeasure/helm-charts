ARG SPARK_IMAGE=apache/spark:3.5.8
FROM ${SPARK_IMAGE}

ARG LIVY_VERSION=0.9.0-incubating
ARG SCALA_BINARY_VERSION=2.12
ARG LIVY_DIST_URL=https://downloads.apache.org/incubator/livy/${LIVY_VERSION}/apache-livy-${LIVY_VERSION}_${SCALA_BINARY_VERSION}-bin.zip

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl unzip; \
    curl -fsSL "${LIVY_DIST_URL}" -o /tmp/livy.zip; \
    unzip /tmp/livy.zip -d /opt; \
    mv "/opt/apache-livy-${LIVY_VERSION}_${SCALA_BINARY_VERSION}-bin" /opt/livy; \
    rm -f /tmp/livy.zip; \
    mkdir -p /opt/livy/conf /opt/livy/logs /opt/spark/conf; \
    chown -R 185:0 /opt/livy /opt/spark/conf; \
    chmod -R g=u /opt/livy /opt/spark/conf; \
    apt-get purge -y --auto-remove curl unzip; \
    rm -rf /var/lib/apt/lists/*

ENV LIVY_HOME=/opt/livy \
    LIVY_CONF_DIR=/opt/livy/conf \
    SPARK_HOME=/opt/spark \
    SPARK_CONF_DIR=/opt/spark/conf

USER 185
EXPOSE 8998

CMD ["/opt/livy/bin/livy-server"]
