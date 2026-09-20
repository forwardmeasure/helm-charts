/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements. See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.forwardmeasure.keycloak.authorization;

import java.util.HashMap;
import java.util.Map;
import org.keycloak.Config;
import org.keycloak.authorization.AuthorizationProvider;
import org.keycloak.authorization.model.Policy;
import org.keycloak.authorization.policy.provider.PolicyProvider;
import org.keycloak.authorization.policy.provider.PolicyProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.representations.idm.authorization.PolicyRepresentation;

/**
 * Registered via {@code META-INF/services/org.keycloak.authorization.policy.provider.
 * PolicyProviderFactory} - discovered by Keycloak's own SPI loader at server build/boot time, the
 * same mechanism every built-in policy type (Regex, Role, Group, ...) uses. See {@link
 * OrganizationRolePolicyProvider}'s own javadoc for why this exists.
 *
 * <p>Deliberately reuses the generic {@link PolicyRepresentation} (raw {@code config} map) rather
 * than a dedicated representation subtype - this policy is provisioned exclusively through the
 * Admin REST API with a plain JSON config (matching {@code openworkflow-k2-security}'s own
 * bootstrap.sh convention for every other policy type it creates), never through the Admin Console
 * UI, so no typed representation/UI metadata is needed.
 */
public class OrganizationRolePolicyProviderFactory
    implements PolicyProviderFactory<PolicyRepresentation> {

  static final String PROVIDER_ID = "organization-role";

  private final OrganizationRolePolicyProvider provider = new OrganizationRolePolicyProvider();

  @Override
  public String getId() {
    return PROVIDER_ID;
  }

  @Override
  public String getName() {
    return "Organization Role";
  }

  @Override
  public String getGroup() {
    return "Identity Based";
  }

  @Override
  public PolicyProvider create(AuthorizationProvider authorization) {
    return provider;
  }

  @Override
  public PolicyProvider create(KeycloakSession session) {
    return provider;
  }

  @Override
  public PolicyRepresentation toRepresentation(Policy policy, AuthorizationProvider authorization) {
    PolicyRepresentation representation = new PolicyRepresentation();
    representation.setConfig(new HashMap<>(policy.getConfig()));
    return representation;
  }

  @Override
  public Class<PolicyRepresentation> getRepresentationType() {
    return PolicyRepresentation.class;
  }

  @Override
  public void onCreate(Policy policy, PolicyRepresentation representation, AuthorizationProvider authorization) {
    updateConfig(policy, representation);
  }

  @Override
  public void onUpdate(Policy policy, PolicyRepresentation representation, AuthorizationProvider authorization) {
    updateConfig(policy, representation);
  }

  private static void updateConfig(Policy policy, PolicyRepresentation representation) {
    Map<String, String> config = new HashMap<>(policy.getConfig());
    if (representation.getConfig() != null) {
      config.putAll(representation.getConfig());
    }
    policy.setConfig(config);
  }

  @Override
  public void init(Config.Scope config) {}

  @Override
  public void postInit(KeycloakSessionFactory factory) {}

  @Override
  public void close() {}
}
