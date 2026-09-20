#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Layers policy-provider/ (a real Keycloak Authorization Services Policy Provider SPI
# implementation - see that module's own README/javadoc for the real, decompiled-source-verified
# gap it fixes: a role granted via Keycloak Organizations group membership is invisible to every
# built-in policy type) onto the same official image this chart already deploys - not a from-scratch
# build. Must be rebuilt whenever the base tag/digest in this chart's values.yaml changes, since a
# provider JAR built against one Keycloak minor version's SPI classes is not guaranteed binary
# compatible with another.
#
# The real source of truth for the Keycloak version is helm-chart-sources/values.yaml's own
# `keycloakVersion` - build-and-push-image.sh reads it from there and passes it as the
# KEYCLOAK_BASE_IMAGE build-arg below, so this ARG's own default only matters for a manual
# `docker build` run directly against this file. Keep it in sync with values.yaml by hand if you
# ever change one without running the build script.
ARG KEYCLOAK_BASE_IMAGE=quay.io/keycloak/keycloak:26.7.4

FROM ${KEYCLOAK_BASE_IMAGE}

COPY policy-provider/target/forwardmeasure-keycloak-authorization-policy-provider.jar /opt/keycloak/providers/

# Keycloak's Quarkus-based distribution does ahead-of-time provider discovery/optimization at
# `kc.sh build` time, not at boot - a provider JAR dropped in without this step is not registered
# (confirmed against the real behavior: `kc.sh show-config` after a bare COPY, with no rebuild,
# does not list the new provider under any SPI). Re-running the SAME build flags the base image's
# own build already used keeps the rest of its build-time config (features, db vendor, etc.)
# unchanged - see this chart's own values.yaml `realm.features` for the real, current feature set.
RUN /opt/keycloak/bin/kc.sh build
