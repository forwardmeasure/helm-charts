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

import org.jboss.logging.Logger;
import org.keycloak.authorization.AuthorizationProvider;
import org.keycloak.authorization.attribute.Attributes;
import org.keycloak.authorization.model.Policy;
import org.keycloak.authorization.model.ResourceServer;
import org.keycloak.authorization.policy.evaluation.Evaluation;
import org.keycloak.authorization.policy.provider.PolicyProvider;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.OrganizationModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.organization.OrganizationProvider;

/**
 * Real fix for a confirmed gap in Keycloak 26.7.4: a role granted to an identity via Keycloak
 * Organizations group membership is invisible to every built-in Authorization Services policy type
 * (Regex, Role, Group, ...) - verified directly against decompiled Keycloak 26.7.4 source, not
 * assumed. {@code UserModelIdentity.hasClientRole}/{@code hasRole} (the mechanism every built-in
 * policy type ultimately calls) delegates to plain {@code UserModel#hasRole}, which only resolves
 * direct role grants and realm-group inheritance - Organization-scoped groups are a structurally
 * separate model Keycloak's own admin API explicitly refuses to reference from a Group-type policy
 * ("Organization groups cannot be used. Only realm groups are allowed."). This provider bypasses
 * that entire layer: it resolves the caller's Organization membership and role directly through
 * {@link OrganizationProvider}, the same real, authoritative Java SPI Keycloak's own Organizations
 * admin REST endpoints use - not a token claim, not a caller-supplied request property, no
 * serialization step to get wrong.
 *
 * <p>Deliberately requires the caller (the real, trusted resource-server client - see {@link
 * com.forwardmeasure.authzen.client.AuthzenAuthorizationService} in forwardmeasure-authzen, the only
 * real caller of this policy) to declare which Organization the request is scoped to, via the AuthZEN
 * evaluation request's {@code context.active_organization_id} - already sent on every real
 * evaluation call today. This mirrors {@code PROJECT_MANIFESTO.md}'s own anti-merge principle
 * exactly: a role is only honored for the one Organization the caller explicitly asserts as active
 * for this request, never merged across every Organization the identity happens to belong to. The
 * assertion itself is cross-checked, not blindly trusted: {@link OrganizationModel#isMember} must
 * independently confirm the resolved user is a real member of that exact Organization before the
 * role check ever runs.
 */
public class OrganizationRolePolicyProvider implements PolicyProvider {

  private static final Logger LOG = Logger.getLogger(OrganizationRolePolicyProvider.class);

  static final String CONFIG_ROLE = "role";
  static final String CONTEXT_ACTIVE_ORGANIZATION_ID = "active_organization_id";

  @Override
  public void evaluate(Evaluation evaluation) {
    Policy policy = evaluation.getPolicy();
    String roleName = policy.getConfig().get(CONFIG_ROLE);
    if (roleName == null || roleName.isBlank()) {
      // Misconfigured policy - fail closed, not open. Never silently grant on bad config.
      LOG.warnf("Policy %s has no configured role - denying", policy.getName());
      return;
    }

    AuthorizationProvider authorization = evaluation.getAuthorizationProvider();
    KeycloakSession session = authorization.getKeycloakSession();
    RealmModel realm = session.getContext().getRealm();

    String userId = evaluation.getContext().getIdentity().getId();
    UserModel user = session.users().getUserById(realm, userId);
    if (user == null) {
      return;
    }

    String activeOrganizationId =
        singleValue(evaluation.getContext().getAttributes(), CONTEXT_ACTIVE_ORGANIZATION_ID);
    if (activeOrganizationId == null) {
      return;
    }

    OrganizationProvider organizations = session.getProvider(OrganizationProvider.class);
    OrganizationModel organization = organizations.getById(activeOrganizationId);
    // Cross-checked against real membership, not just trusted from the caller's own assertion -
    // see this class's own javadoc for why this matters.
    if (organization == null || !organization.isMember(user)) {
      return;
    }

    ResourceServer resourceServer = policy.getResourceServer();
    ClientModel client = realm.getClientById(resourceServer.getClientId());
    if (client == null) {
      return;
    }
    RoleModel role = client.getRole(roleName);
    if (role == null) {
      return;
    }

    boolean hasOrganizationRole =
        organizations.getOrganizationGroupsByMember(organization, user).anyMatch(group -> group.hasRole(role));
    LOG.debugf(
        "Policy %s: user=%s organization=%s role=%s -> %s",
        policy.getName(), userId, activeOrganizationId, roleName, hasOrganizationRole ? "GRANT" : "DENY");
    if (hasOrganizationRole) {
      evaluation.grant();
    }
  }

  private static String singleValue(Attributes attributes, String name) {
    if (!attributes.exists(name)) {
      return null;
    }
    Attributes.Entry value = attributes.getValue(name);
    return value.isEmpty() ? null : value.asString(0);
  }

  @Override
  public void close() {}
}
