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

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import org.keycloak.authorization.AuthorizationProvider;
import org.keycloak.authorization.attribute.Attributes;
import org.keycloak.authorization.identity.Identity;
import org.keycloak.authorization.model.Policy;
import org.keycloak.authorization.model.ResourceServer;
import org.keycloak.authorization.policy.evaluation.Evaluation;
import org.keycloak.authorization.policy.evaluation.EvaluationContext;
import org.keycloak.models.ClientModel;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.OrganizationModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.organization.OrganizationProvider;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * Exercises {@link OrganizationRolePolicyProvider#evaluate} against mocked Keycloak SPI types -
 * proves the grant/deny logic in isolation. Does NOT prove the real Keycloak server actually
 * discovers/wires this provider correctly (SPI registration, {@code kc.sh build}, real Organization
 * data) - that needs a real running Keycloak with this provider JAR installed, not yet done. See
 * this module's own README/handover note for what's still open.
 */
class OrganizationRolePolicyProviderTest {

  private static final String ROLE_NAME = "workflow-author";
  private static final String ORGANIZATION_ID = "org-1";
  private static final String USER_ID = "user-1";
  private static final String CLIENT_INTERNAL_ID = "client-internal-1";

  private OrganizationRolePolicyProvider provider;
  private Evaluation evaluation;
  private KeycloakSession session;
  private RealmModel realm;
  private UserModel user;
  private OrganizationProvider organizations;
  private OrganizationModel organization;
  private ClientModel client;
  private RoleModel role;
  private Policy policy;
  private Attributes contextAttributes;

  @BeforeEach
  void setUp() {
    provider = new OrganizationRolePolicyProvider();

    policy = mock(Policy.class);
    when(policy.getConfig()).thenReturn(Map.of("role", ROLE_NAME));

    ResourceServer resourceServer = mock(ResourceServer.class);
    when(resourceServer.getClientId()).thenReturn(CLIENT_INTERNAL_ID);
    when(policy.getResourceServer()).thenReturn(resourceServer);

    session = mock(KeycloakSession.class);
    realm = mock(RealmModel.class);
    KeycloakContext keycloakContext = mock(KeycloakContext.class);
    when(keycloakContext.getRealm()).thenReturn(realm);
    when(session.getContext()).thenReturn(keycloakContext);

    user = mock(UserModel.class);
    UserProvider users = mock(UserProvider.class);
    when(users.getUserById(realm, USER_ID)).thenReturn(user);
    when(session.users()).thenReturn(users);

    organizations = mock(OrganizationProvider.class);
    when(session.getProvider(OrganizationProvider.class)).thenReturn(organizations);

    organization = mock(OrganizationModel.class);
    when(organizations.getById(ORGANIZATION_ID)).thenReturn(organization);
    when(organization.isMember(user)).thenReturn(true);

    client = mock(ClientModel.class);
    when(realm.getClientById(CLIENT_INTERNAL_ID)).thenReturn(client);
    role = mock(RoleModel.class);
    when(client.getRole(ROLE_NAME)).thenReturn(role);

    AuthorizationProvider authorization = mock(AuthorizationProvider.class);
    when(authorization.getKeycloakSession()).thenReturn(session);

    Identity identity = mock(Identity.class);
    when(identity.getId()).thenReturn(USER_ID);

    contextAttributes = mock(Attributes.class);
    EvaluationContext evaluationContext = mock(EvaluationContext.class);
    when(evaluationContext.getIdentity()).thenReturn(identity);
    when(evaluationContext.getAttributes()).thenReturn(contextAttributes);

    evaluation = mock(Evaluation.class);
    when(evaluation.getPolicy()).thenReturn(policy);
    when(evaluation.getAuthorizationProvider()).thenReturn(authorization);
    when(evaluation.getContext()).thenReturn(evaluationContext);
  }

  private void withActiveOrganizationId(String value) {
    when(contextAttributes.exists("active_organization_id")).thenReturn(true);
    Attributes.Entry entry = mock(Attributes.Entry.class);
    when(entry.isEmpty()).thenReturn(false);
    when(entry.asString(0)).thenReturn(value);
    when(contextAttributes.getValue("active_organization_id")).thenReturn(entry);
  }

  private void withNoActiveOrganizationId() {
    when(contextAttributes.exists("active_organization_id")).thenReturn(false);
  }

  private void memberOfGroupWithRole(boolean hasRole) {
    GroupModel group = mock(GroupModel.class);
    when(group.hasRole(role)).thenReturn(hasRole);
    when(organizations.getOrganizationGroupsByMember(organization, user)).thenReturn(Stream.of(group));
  }

  @Test
  void grantsWhenMemberOfActiveOrganizationsGroupHoldingTheRole() {
    withActiveOrganizationId(ORGANIZATION_ID);
    memberOfGroupWithRole(true);

    provider.evaluate(evaluation);

    verify(evaluation).grant();
  }

  @Test
  void deniesWhenNoActiveOrganizationIdIsAsserted() {
    withNoActiveOrganizationId();

    provider.evaluate(evaluation);

    verify(evaluation, never()).grant();
  }

  @Test
  void deniesWhenAssertedOrganizationDoesNotExist() {
    withActiveOrganizationId("does-not-exist");
    when(organizations.getById("does-not-exist")).thenReturn(null);

    provider.evaluate(evaluation);

    verify(evaluation, never()).grant();
  }

  @Test
  void deniesWhenUserIsNotARealMemberOfTheAssertedOrganization() {
    withActiveOrganizationId(ORGANIZATION_ID);
    // The caller asserts membership, but real OrganizationModel#isMember says otherwise - the
    // cross-check this provider's own javadoc promises, not a blind trust of the caller's claim.
    when(organization.isMember(user)).thenReturn(false);

    provider.evaluate(evaluation);

    verify(evaluation, never()).grant();
  }

  @Test
  void deniesWhenMemberOfTheOrganizationButNoGroupThereHoldsTheRole() {
    withActiveOrganizationId(ORGANIZATION_ID);
    memberOfGroupWithRole(false);

    provider.evaluate(evaluation);

    verify(evaluation, never()).grant();
  }

  @Test
  void deniesWhenPolicyConfigHasNoRole() {
    when(policy.getConfig()).thenReturn(Map.of());

    provider.evaluate(evaluation);

    verify(evaluation, never()).grant();
    // Fails closed before ever touching the session - confirms no partial side effects on bad config.
    verify(session, never()).users();
  }

  @Test
  void deniesWhenTheRoleDoesNotExistOnTheResourceServersClient() {
    withActiveOrganizationId(ORGANIZATION_ID);
    when(client.getRole(ROLE_NAME)).thenReturn(null);

    provider.evaluate(evaluation);

    verify(evaluation, never()).grant();
  }

  @Test
  void deniesWhenTheResolvedUserDoesNotExist() {
    withActiveOrganizationId(ORGANIZATION_ID);
    UserProvider users = session.users();
    when(users.getUserById(realm, USER_ID)).thenReturn(null);

    provider.evaluate(evaluation);

    verify(evaluation, never()).grant();
  }
}
