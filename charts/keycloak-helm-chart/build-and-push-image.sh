#!/bin/bash
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
# Builds the policy-provider/ jar, then builds and pushes the custom Keycloak image (official
# Keycloak + the "organization-role" Policy Provider baked in) that helm-chart-sources/values.yaml's
# own image.repository/tag default now points at. The Keycloak version comes from
# helm-chart-sources/values.yaml's own `keycloakVersion` - the single source of truth this whole
# chart keys off - not a separately-maintained literal here.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

KEYCLOAK_VERSION="$(yq eval '.keycloakVersion' "${SCRIPT_DIR}/helm-chart-sources/values.yaml")"

DOCKER_REGISTRY="${DOCKER_REGISTRY:-docker.io}"
DOCKER_REPOSITORY="${DOCKER_REPOSITORY:-forwardmeasure}"
DOCKER_IMAGE_NAME="${DOCKER_IMAGE_NAME:-keycloak}"
DOCKER_TAG="${DOCKER_TAG:-${KEYCLOAK_VERSION}-authz}"

DOCKER_REFERENCE="${DOCKER_REGISTRY}/${DOCKER_REPOSITORY}/${DOCKER_IMAGE_NAME}:${DOCKER_TAG}"
KEYCLOAK_BASE_IMAGE="${KEYCLOAK_BASE_IMAGE:-quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}}"

# Deliberately runs the real unit tests (no -DskipTests) - this is the one gate standing between a
# broken OrganizationRolePolicyProvider and a pushed, deployed image. Never skip it here.
mvn -f "${SCRIPT_DIR}/policy-provider/pom.xml" -q package

docker build \
  --build-arg KEYCLOAK_BASE_IMAGE="${KEYCLOAK_BASE_IMAGE}" \
  -t "${DOCKER_REFERENCE}" \
  -f "${SCRIPT_DIR}/Dockerfile" \
  "${SCRIPT_DIR}"

docker push "${DOCKER_REFERENCE}"

echo "Pushed ${DOCKER_REFERENCE}"
echo "Digest: $(docker inspect --format='{{index .RepoDigests 0}}' "${DOCKER_REFERENCE}")"
