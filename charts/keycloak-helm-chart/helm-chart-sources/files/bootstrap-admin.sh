#!/usr/bin/env sh
set -eu

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  printf '%s INFO  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

log_section() {
  printf '%s ----- %s -----\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

fail() {
  printf '%s ERROR %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  exit 1
}

require_env() {
  var="$1"
  eval "val=\${$var:-}"
  [ -n "$val" ] || fail "Required env var '$var' is not set"
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

json_escape() {
  printf '%s' "$1" | jq -R .
}

kc_get() {
  url="$1"
  out="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "$url")"
  if [ "$out" != "200" ]; then
    log "GET $url -> HTTP $out: $(cat /tmp/kc.out 2>/dev/null || true)" >&2
    return 1
  fi
  cat /tmp/kc.out
}

kc_post_json() {
  url="$1"
  body="$2"
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$url" \
    --data "$body")"
  if [ "$code" != "201" ] && [ "$code" != "204" ] && [ "$code" != "409" ]; then
    cat /tmp/kc.out >&2 || true
    fail "POST $url failed with HTTP $code"
  fi
  if [ "$code" = "409" ]; then
    log "POST $url returned 409 (already exists) — skipping"
  fi
}

kc_put_json() {
  url="$1"
  body="$2"
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$url" \
    --data "$body")"
  if [ "$code" != "204" ]; then
    cat /tmp/kc.out >&2 || true
    fail "PUT $url failed with HTTP $code"
  fi
}

kc_put_no_body() {
  url="$1"
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    "$url")"
  if [ "$code" != "204" ]; then
    cat /tmp/kc.out >&2 || true
    fail "PUT $url failed with HTTP $code"
  fi
}

kc_delete_json() {
  url="$1"
  body="$2"
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$url" \
    --data "$body")"
  if [ "$code" != "204" ]; then
    cat /tmp/kc.out >&2 || true
    fail "DELETE $url failed with HTTP $code"
  fi
}

kc_delete_no_body() {
  url="$1"
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "$url")"
  if [ "$code" != "204" ]; then
    cat /tmp/kc.out >&2 || true
    fail "DELETE $url failed with HTTP $code"
  fi
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

print_config_banner() {
  log_section "Bootstrap configuration"
  log "KEYCLOAK_URL                            = ${KEYCLOAK_URL}"
  log "REALM                                   = ${REALM}"
  log "REALM_LOGIN_THEME                       = ${REALM_LOGIN_THEME}"
  log "KEYCLOAK_ADMIN                          = ${KEYCLOAK_ADMIN}"
  log "ADMIN_USERNAME                          = ${ADMIN_USERNAME}"
  log "ADMIN_EMAIL                             = ${ADMIN_EMAIL}"
  log "ADMIN_FIRST_NAME                        = ${ADMIN_FIRST_NAME}"
  log "ADMIN_LAST_NAME                         = ${ADMIN_LAST_NAME}"
  log "ADMIN_TENANT_DID                        = ${ADMIN_TENANT_DID}"
  log "ADMIN_ACTOR_DID                         = ${ADMIN_ACTOR_DID}"
  log "ADMIN_ACTOR_TYPE                        = ${ADMIN_ACTOR_TYPE}"
  log "FORWARDMEASURE_ROLE_VIEWER                  = ${FORWARDMEASURE_ROLE_VIEWER}"
  log "FORWARDMEASURE_ROLE_ACCESS_ADMIN            = ${FORWARDMEASURE_ROLE_ACCESS_ADMIN}"
  log "FORWARDMEASURE_ROLE_PLATFORM_ADMIN          = ${FORWARDMEASURE_ROLE_PLATFORM_ADMIN}"
  log "FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID = ${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}"
  log "FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID       = ${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}"
  log "FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_REDIRECT_URIS_JSON = ${FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_REDIRECT_URIS_JSON}"
  log "FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_WEB_ORIGINS_JSON   = ${FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_WEB_ORIGINS_JSON}"
  log "KEYCLOAK_REALM_MGMT_ROLES               = ${KEYCLOAK_REALM_MGMT_ROLES}"
  log "FORWARDMEASURE_TENANT_GROUP_ROLES           = ${FORWARDMEASURE_TENANT_GROUP_ROLES:-<empty>}"
  log "FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS    = ${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS:-<empty>}"
  log "FORWARDMEASURE_TENANT_ORGANIZATION_ROLE     = ${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE:-<empty>}"
  log "KEYCLOAK_READY_SLEEP_SECONDS            = ${KEYCLOAK_READY_SLEEP_SECONDS}"
  log "KEYCLOAK_READY_MAX_ATTEMPTS             = ${KEYCLOAK_READY_MAX_ATTEMPTS}"
  log_section "Starting bootstrap"
}

configure_realm_theme() {
  log_section "Realm theme configuration"
  body="$(jq -n --arg login_theme "${REALM_LOGIN_THEME}" '{loginTheme: $login_theme}')"
  kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}" "$body"
  log "Realm login theme reconciled: ${REALM_LOGIN_THEME}"
}

# Every realm has used Keycloak's declarative User Profile since 24.x,
# whether or not it's ever explicitly configured (this realm's own import
# JSON has no UserProfileProvider component at all, so it runs on whatever
# Keycloak's own default is). Left unset, that default silently DROPS any
# attribute not declared in the profile's own schema on write - the request
# itself still succeeds (kc_put_json below sees the same 204 it always
# does), it just never persists. Confirmed the hard way: create_or_update_
# bootstrap_user's PUT to set tenant_did/actor_did/actor_type reported
# success on every run, but a real issued token never once carried any of
# the three - the forwardmeasure_identity scope's mappers had nothing to
# map. GET-then-PUT, not a blind PUT: the current config's own declared
# attributes/groups (Keycloak's built-in username/email/firstName/lastName
# schema) must survive this, only unmanagedAttributePolicy is being added.
configure_user_profile_unmanaged_attributes() {
  log_section "User profile: allow unmanaged attributes"
  current="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/users/profile")"
  body="$(printf '%s' "$current" | jq '.unmanagedAttributePolicy = "ENABLED"')"
  # Not kc_put_json: that helper requires a bare 204, which matches
  # resource-style endpoints (e.g. the user PUT below) but not this one -
  # PUT .../users/profile is a configuration-object endpoint and Keycloak's
  # admin REST API conventionally returns 200 with the updated
  # representation for that shape of endpoint, not 204. The first version
  # of this function used kc_put_json here and the Job failed - the pod
  # was garbage-collected before its logs could be read to confirm the
  # exact status code, so this accepts either rather than guessing which
  # one it actually was.
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/profile" \
    --data "$body")"
  case "$code" in
    200 | 204) ;;
    *)
      cat /tmp/kc.out >&2 || true
      fail "PUT ${KEYCLOAK_URL}/admin/realms/${REALM}/users/profile failed with HTTP ${code}"
      ;;
  esac
  log "User profile now allows unmanaged attributes (tenant_did/actor_did/actor_type)"
}

# ---------------------------------------------------------------------------
# Keycloak readiness
# ---------------------------------------------------------------------------

wait_for_keycloak() {
  log "Polling ${KEYCLOAK_URL}/realms/${REALM} ..."
  attempt=1
  while :; do
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' "${KEYCLOAK_URL}/realms/${REALM}" 2>/dev/null || true)"
    if [ "$http_code" = "200" ]; then
      log "Keycloak is ready (HTTP 200)"
      return 0
    fi
    if [ "$attempt" -ge "${KEYCLOAK_READY_MAX_ATTEMPTS}" ]; then
      fail "Keycloak not ready after ${KEYCLOAK_READY_MAX_ATTEMPTS} attempts (last HTTP status: ${http_code})"
    fi
    log "Keycloak not ready yet (attempt ${attempt}/${KEYCLOAK_READY_MAX_ATTEMPTS}, HTTP ${http_code}) — retrying in ${KEYCLOAK_READY_SLEEP_SECONDS}s"
    attempt=$((attempt + 1))
    sleep "${KEYCLOAK_READY_SLEEP_SECONDS}"
  done
}

# ---------------------------------------------------------------------------
# Realm import readiness
# ---------------------------------------------------------------------------

# wait_for_keycloak confirms only that the realm endpoint responds with HTTP 200.
# It does NOT confirm that the realm import has completed and all built-in clients
# (e.g. realm-management) are visible. This function waits for realm-management
# specifically, since Phase 3 depends on it to assign service account roles.
# Without this guard, the bootstrap Job races against the async realm import and
# Phase 3 fails silently or with a 403.
wait_for_realm_management_client() {
  log "Waiting for realm-management client to be visible in realm '${REALM}'..."
  attempt=1
  while :; do
    uuid="$(get_client_uuid_by_client_id "realm-management" 2>/dev/null || true)"
    if [ -n "$uuid" ] && [ "$uuid" != "null" ]; then
      log "realm-management client is visible (uuid=${uuid})"
      return 0
    fi
    if [ "$attempt" -ge "${KEYCLOAK_READY_MAX_ATTEMPTS}" ]; then
      fail "realm-management client not visible after ${KEYCLOAK_READY_MAX_ATTEMPTS} attempts — realm import may have failed or stalled"
    fi
    log "realm-management not yet visible (attempt ${attempt}/${KEYCLOAK_READY_MAX_ATTEMPTS}) — retrying in ${KEYCLOAK_READY_SLEEP_SECONDS}s"
    attempt=$((attempt + 1))
    sleep "${KEYCLOAK_READY_SLEEP_SECONDS}"
  done
}

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

fetch_admin_token() {
  log "Fetching admin token from ${KEYCLOAK_URL}/realms/master (user: ${KEYCLOAK_ADMIN})"
  TOKEN="$(
    curl -fsS \
      -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "client_id=admin-cli" \
      -d "username=${KEYCLOAK_ADMIN}" \
      -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
      -d "grant_type=password" \
      | jq -r '.access_token'
  )"
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "Failed to obtain admin token — check KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD"
  export TOKEN
  log "Admin token obtained successfully"
}

# ---------------------------------------------------------------------------
# Realm roles
# ---------------------------------------------------------------------------

ensure_realm_role() {
  role_name="$1"
  description="$2"
  log "Checking realm role: ${role_name}"
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/roles/${role_name}")"
  if [ "$code" = "200" ]; then
    log "Realm role already exists: ${role_name}"
    return 0
  fi
  [ "$code" = "404" ] || fail "Unexpected HTTP $code checking realm role '${role_name}'"
  log "Creating realm role: ${role_name}"
  body="$(cat <<EOF
{
  "name": $(json_escape "$role_name"),
  "description": $(json_escape "$description")
}
EOF
)"
  kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/roles" "$body"
  log "Created realm role: ${role_name}"
}

get_realm_role_json() {
  role_name="$1"
  kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/roles/${role_name}" \
    || fail "Could not fetch realm role '${role_name}'"
}

ensure_composite_role() {
  parent="$1"
  child="$2"
  log "Checking composite role: ${parent} -> ${child}"
  parent_json="$(get_realm_role_json "$parent")"
  parent_id="$(printf '%s' "$parent_json" | jq -r '.id')"
  [ -n "$parent_id" ] && [ "$parent_id" != "null" ] || fail "Missing id for role '${parent}'"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/roles-by-id/${parent_id}/composites" \
    | jq -r '.[].name' || true)"
  if printf '%s\n' "$existing" | grep -qx "$child"; then
    log "Composite already present: ${parent} -> ${child}"
    return 0
  fi
  log "Adding composite role: ${parent} -> ${child}"
  child_json="$(get_realm_role_json "$child")"
  kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/roles-by-id/${parent_id}/composites" "[$child_json]"
  log "Added composite role: ${parent} -> ${child}"
}

# ---------------------------------------------------------------------------
# Bootstrap user
# ---------------------------------------------------------------------------

get_user_id_by_username() {
  username="$1"
  encoded="$(printf '%s' "$username" | jq -sRr @uri)"
  kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${encoded}" \
    | jq -r '.[0].id // empty'
}

create_or_update_bootstrap_user() {
  log "Looking up bootstrap user: ${ADMIN_USERNAME}"
  user_id="$(get_user_id_by_username "${ADMIN_USERNAME}" || true)"
  user_body="$(cat <<EOF
{
  "username":  $(json_escape "${ADMIN_USERNAME}"),
  "email":     $(json_escape "${ADMIN_EMAIL}"),
  "firstName": $(json_escape "${ADMIN_FIRST_NAME}"),
  "lastName":  $(json_escape "${ADMIN_LAST_NAME}"),
  "enabled": true,
  "emailVerified": true
}
EOF
)"
  user_body="$(printf '%s' "$user_body" | jq \
    --arg tenant_did "$ADMIN_TENANT_DID" \
    --arg actor_did "$ADMIN_ACTOR_DID" \
    --arg actor_type "$ADMIN_ACTOR_TYPE" \
    '.attributes = {
      "tenant_did": [$tenant_did],
      "actor_did": [$actor_did],
      "actor_type": [$actor_type]
    }')"
  if [ -z "$user_id" ]; then
    log "Bootstrap user not found — creating: ${ADMIN_USERNAME}"
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/users" "$user_body"
    i=0
    while [ "$i" -lt 10 ]; do
      user_id="$(get_user_id_by_username "${ADMIN_USERNAME}" || true)"
      [ -n "$user_id" ] && break
      log "User not yet queryable — waiting 2s (attempt $((i + 1))/10)"
      sleep 2
      i=$((i + 1))
    done
    [ -n "$user_id" ] || fail "User POST succeeded but '${ADMIN_USERNAME}' not found after 10 retries"
    log "Bootstrap user created: ${ADMIN_USERNAME} (id=${user_id})"
  else
    log "Bootstrap user found (id=${user_id}) — updating attributes"
    kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}" "$user_body"
    log "Bootstrap user updated: ${ADMIN_USERNAME} (id=${user_id})"
  fi
  BOOTSTRAP_USER_ID="$user_id"
  export BOOTSTRAP_USER_ID
}

set_bootstrap_user_password() {
  log "Setting password for user: ${BOOTSTRAP_USER_ID}"
  body="$(cat <<EOF
{
  "type": "password",
  "value": $(json_escape "${ADMIN_PASSWORD}"),
  "temporary": false
}
EOF
)"
  kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${BOOTSTRAP_USER_ID}/reset-password" "$body"
  log "Password set for user: ${BOOTSTRAP_USER_ID}"
}

assign_realm_role_to_user_if_missing() {
  user_id="$1"
  role_name="$2"
  log "Checking realm role '${role_name}' on user ${user_id}"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/realm" \
    | jq -r '.[].name' || true)"
  if printf '%s\n' "$existing" | grep -qx "$role_name"; then
    log "User ${user_id} already has realm role: ${role_name}"
    return 0
  fi
  log "Assigning realm role '${role_name}' to user ${user_id}"
  role_json="$(get_realm_role_json "$role_name")"
  kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/realm" "[$role_json]"
  log "Assigned realm role '${role_name}' to user ${user_id}"
}

# ---------------------------------------------------------------------------
# Client / service-account helpers
# ---------------------------------------------------------------------------

get_client_uuid_by_client_id() {
  client_id="$1"
  encoded="$(printf '%s' "$client_id" | jq -sRr @uri)"
  kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${encoded}" \
    | jq -r '.[0].id // empty'
}

get_service_account_user_id() {
  client_uuid="$1"
  kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/service-account-user" \
    | jq -r '.id // empty'
}

assign_client_roles_to_user_if_missing() {
  user_id="$1"
  client_uuid="$2"
  roles_csv="$3"
  log "Checking client roles for user ${user_id} on client ${client_uuid}"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/clients/${client_uuid}" \
    | jq -r '.[].name' || true)"
  payload="["
  first="true"
  OLD_IFS="$IFS"
  IFS=','
  for role in $roles_csv; do
    IFS="$OLD_IFS"
    trimmed="$(printf '%s' "$role" | tr -d '[:space:]')"
    [ -n "$trimmed" ] || continue
    if printf '%s\n' "$existing" | grep -qx "$trimmed"; then
      log "User ${user_id} already has client role: ${trimmed}"
    else
      log "Queuing client role for assignment: ${trimmed}"
      role_json="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/roles/${trimmed}" \
        || fail "Could not fetch client role '${trimmed}' from client ${client_uuid}")"
      if [ "$first" = "true" ]; then
        payload="${payload}${role_json}"
        first="false"
      else
        payload="${payload},${role_json}"
      fi
    fi
    IFS=','
  done
  IFS="$OLD_IFS"
  payload="${payload}]"
  if [ "$payload" != "[]" ]; then
    log "Assigning queued client roles to user ${user_id}"
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/clients/${client_uuid}" "$payload"
    log "Client roles assigned to user ${user_id}"
  else
    log "No new client roles to assign for user ${user_id}"
  fi
}

# ---------------------------------------------------------------------------
# Client scope helpers
# ---------------------------------------------------------------------------

get_scope_id_by_name() {
  scope_name="$1"
  kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    | jq -r --arg n "$scope_name" '.[] | select(.name==$n) | .id' \
    | tr -d '\n'
}

ensure_client_scope() {
  scope_name="$1"
  scope_body="$2"
  log "Checking client scope: ${scope_name}"
  existing_id="$(get_scope_id_by_name "$scope_name" || true)"
  if [ -n "$existing_id" ]; then
    log "Client scope already exists: ${scope_name} (id=${existing_id})"
    printf '%s' "$existing_id"
    return 0
  fi
  log "Creating client scope: ${scope_name}"
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    --data "$scope_body")"
  if [ "$code" != "201" ] && [ "$code" != "409" ]; then
    cat /tmp/kc.out >&2 || true
    fail "POST client-scope '${scope_name}' failed with HTTP $code"
  fi
  if [ "$code" = "409" ]; then
    log "Client scope '${scope_name}' already exists (409) — skipping creation"
  fi
  new_id="$(get_scope_id_by_name "$scope_name")"
  [ -n "$new_id" ] || fail "Created scope '${scope_name}' but could not retrieve its UUID"
  log "Created client scope: ${scope_name} (id=${new_id})"
  printf '%s' "$new_id"
}

ensure_scope_forwardmeasure_identity() {
  scope_body="$(cat <<'EOF'
{
  "name": "forwardmeasure_identity",
  "description": "Canonical tenant and actor identity claims for ForwardMeasure tokens",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "false"
  },
  "protocolMappers": [
    {
      "name": "tenant-did",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "consentRequired": false,
      "config": {
        "user.attribute": "tenant_did",
        "claim.name": "tenant_did",
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "multivalued": "false",
        "aggregate.attrs": "false"
      }
    },
    {
      "name": "actor-did",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "consentRequired": false,
      "config": {
        "user.attribute": "actor_did",
        "claim.name": "actor_did",
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "multivalued": "false",
        "aggregate.attrs": "false"
      }
    },
    {
      "name": "actor-type",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "consentRequired": false,
      "config": {
        "user.attribute": "actor_type",
        "claim.name": "actor_type",
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "multivalued": "false",
        "aggregate.attrs": "false"
      }
    }
  ]
}
EOF
)"
  scope_id="$(ensure_client_scope "forwardmeasure_identity" "$scope_body")"
  kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${scope_id}" "$scope_body"
  log "Canonical identity client scope reconciled (id=${scope_id})"
  printf '%s' "$scope_id"
}

assign_default_scope_to_client_if_missing() {
  client_uuid="$1"
  scope_name="$2"
  scope_id="$3"
  log "Checking default scope '${scope_name}' on client ${client_uuid}"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/default-client-scopes" \
    | jq -r '.[].name' || true)"
  if printf '%s\n' "$existing" | grep -qx "$scope_name"; then
    log "Default scope '${scope_name}' already assigned to client ${client_uuid}"
    return 0
  fi
  log "Assigning default scope '${scope_name}' to client ${client_uuid}"
  kc_put_no_body "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/default-client-scopes/${scope_id}"
  log "Assigned default scope '${scope_name}' to client ${client_uuid}"
}

assign_optional_scope_to_client_if_missing() {
  client_uuid="$1"
  scope_name="$2"
  scope_id="$3"
  log "Checking optional scope '${scope_name}' on client ${client_uuid}"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/optional-client-scopes" \
    | jq -r '.[].name' || true)"
  if printf '%s\n' "$existing" | grep -qx "$scope_name"; then
    log "Optional scope '${scope_name}' already assigned to client ${client_uuid}"
    return 0
  fi
  log "Assigning optional scope '${scope_name}' to client ${client_uuid}"
  kc_put_no_body "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/optional-client-scopes/${scope_id}"
  log "Assigned optional scope '${scope_name}' to client ${client_uuid}"
}

# ---------------------------------------------------------------------------
# Built-in scope definitions
# ---------------------------------------------------------------------------

ensure_scope_roles() {
  ensure_client_scope "roles" "$(cat <<'EOF'
{
  "name": "roles",
  "description": "OpenID Connect scope for add user roles to the access token",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "false",
    "display.on.consent.screen": "true",
    "consent.screen.text": "${rolesScopeConsentText}"
  },
  "protocolMappers": [
    {
      "name": "realm roles",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-realm-role-mapper",
      "consentRequired": false,
      "config": {
        "multivalued": "true",
        "user.attribute": "foo",
        "access.token.claim": "true",
        "claim.name": "realm_access.roles",
        "jsonType.label": "String"
      }
    },
    {
      "name": "client roles",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-client-role-mapper",
      "consentRequired": false,
      "config": {
        "multivalued": "true",
        "user.attribute": "foo",
        "access.token.claim": "true",
        "claim.name": "resource_access.${client_id}.roles",
        "jsonType.label": "String"
      }
    },
    {
      "name": "audience resolve",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-resolve-mapper",
      "consentRequired": false,
      "config": {}
    }
  ]
}
EOF
)"
}

ensure_scope_profile() {
  ensure_client_scope "profile" "$(cat <<'EOF'
{
  "name": "profile",
  "description": "OpenID Connect built-in scope: profile",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "true",
    "consent.screen.text": "${profileScopeConsentText}"
  },
  "protocolMappers": [
    {
      "name": "username",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "username",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "preferred_username",
        "jsonType.label": "String"
      }
    },
    {
      "name": "full name",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-full-name-mapper",
      "consentRequired": false,
      "config": {
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    },
    {
      "name": "family name",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "lastName",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "family_name",
        "jsonType.label": "String"
      }
    },
    {
      "name": "given name",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "firstName",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "given_name",
        "jsonType.label": "String"
      }
    },
    {
      "name": "updated at",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "updatedAt",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "updated_at",
        "jsonType.label": "long"
      }
    }
  ]
}
EOF
)"
}

ensure_scope_email() {
  ensure_client_scope "email" "$(cat <<'EOF'
{
  "name": "email",
  "description": "OpenID Connect built-in scope: email",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "true",
    "consent.screen.text": "${emailScopeConsentText}"
  },
  "protocolMappers": [
    {
      "name": "email",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "email",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "email",
        "jsonType.label": "String"
      }
    },
    {
      "name": "email verified",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "emailVerified",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "email_verified",
        "jsonType.label": "boolean"
      }
    }
  ]
}
EOF
)"
}

ensure_scope_web_origins() {
  ensure_client_scope "web-origins" "$(cat <<'EOF'
{
  "name": "web-origins",
  "description": "OpenID Connect scope for web origins",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "false",
    "display.on.consent.screen": "false",
    "consent.screen.text": ""
  },
  "protocolMappers": [
    {
      "name": "allowed web origins",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-allowed-origins-mapper",
      "consentRequired": false,
      "config": {}
    }
  ]
}
EOF
)"
}

ensure_scope_acr() {
  ensure_client_scope "acr" "$(cat <<'EOF'
{
  "name": "acr",
  "description": "OpenID Connect scope for add acr (authentication context class reference) to the token",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "false",
    "display.on.consent.screen": "false"
  },
  "protocolMappers": [
    {
      "name": "acr loa level",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-acr-mapper",
      "consentRequired": false,
      "config": {
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    }
  ]
}
EOF
)"
}

ensure_scope_openid() {
  ensure_client_scope "openid" "$(cat <<'EOF'
{
  "name": "openid",
  "description": "OpenID Connect built-in scope: openid",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "false"
  },
  "protocolMappers": [
    {
      "name": "sub",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-sub-mapper",
      "consentRequired": false,
      "config": {
        "access.token.claim": "true",
        "id.token.claim": "true"
      }
    }
  ]
}
EOF
)"
}

ensure_scope_address() {
  ensure_client_scope "address" "$(cat <<'EOF'
{
  "name": "address",
  "description": "OpenID Connect built-in scope: address",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "true",
    "consent.screen.text": "${addressScopeConsentText}"
  },
  "protocolMappers": [
    {
      "name": "address",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-address-mapper",
      "consentRequired": false,
      "config": {
        "user.attribute.formatted": "formatted",
        "user.attribute.country": "country",
        "user.attribute.postal_code": "postal_code",
        "userinfo.token.claim": "true",
        "user.attribute.street": "street",
        "id.token.claim": "true",
        "user.attribute.region": "region",
        "access.token.claim": "true",
        "user.attribute.locality": "locality"
      }
    }
  ]
}
EOF
)"
}

ensure_scope_phone() {
  ensure_client_scope "phone" "$(cat <<'EOF'
{
  "name": "phone",
  "description": "OpenID Connect built-in scope: phone",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "true",
    "consent.screen.text": "${phoneScopeConsentText}"
  },
  "protocolMappers": [
    {
      "name": "phone number",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "phoneNumber",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "phone_number",
        "jsonType.label": "String"
      }
    },
    {
      "name": "phone number verified",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "phoneNumberVerified",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "phone_number_verified",
        "jsonType.label": "boolean"
      }
    }
  ]
}
EOF
)"
}

# ---------------------------------------------------------------------------
# Phase 4 orchestration: ensure built-in scopes + assign to clients
# ---------------------------------------------------------------------------

configure_client_scopes() {
  log_section "Phase 4: built-in client scopes"

  log "Ensuring built-in client scopes exist..."
  SCOPE_ID_ROLES="$(ensure_scope_roles)"
  SCOPE_ID_PROFILE="$(ensure_scope_profile)"
  SCOPE_ID_EMAIL="$(ensure_scope_email)"
  SCOPE_ID_WEB_ORIGINS="$(ensure_scope_web_origins)"
  SCOPE_ID_ACR="$(ensure_scope_acr)"
  SCOPE_ID_OPENID="$(ensure_scope_openid)"
  SCOPE_ID_ADDRESS="$(ensure_scope_address)"
  SCOPE_ID_PHONE="$(ensure_scope_phone)"
  SCOPE_ID_OFFLINE="$(get_scope_id_by_name "offline_access")"
  SCOPE_ID_IDENTITY="$(ensure_scope_forwardmeasure_identity)"

  [ -n "$SCOPE_ID_OFFLINE" ] || fail "Could not find scope 'offline_access' — realm import may have failed"
  [ -n "$SCOPE_ID_IDENTITY" ] || fail "Could not reconcile scope 'forwardmeasure_identity'"

  log "All client scopes verified"

  # ForwardMeasure public client
  log "Configuring scopes for client: ${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}"
  admin_pub_uuid="$(get_client_uuid_by_client_id "${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}")"
  [ -n "$admin_pub_uuid" ] || fail "Could not resolve UUID for client '${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}'"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "web-origins"   "$SCOPE_ID_WEB_ORIGINS"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "acr"            "$SCOPE_ID_ACR"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "openid"         "$SCOPE_ID_OPENID"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "roles"          "$SCOPE_ID_ROLES"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "profile"        "$SCOPE_ID_PROFILE"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "email"          "$SCOPE_ID_EMAIL"
  assign_optional_scope_to_client_if_missing "$admin_pub_uuid" "address"        "$SCOPE_ID_ADDRESS"
  assign_optional_scope_to_client_if_missing "$admin_pub_uuid" "phone"          "$SCOPE_ID_PHONE"
  assign_optional_scope_to_client_if_missing "$admin_pub_uuid" "offline_access" "$SCOPE_ID_OFFLINE"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "forwardmeasure_identity" "$SCOPE_ID_IDENTITY"

  # ForwardMeasure confidential client
  log "Configuring scopes for client: ${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}"
  admin_conf_uuid="$(get_client_uuid_by_client_id "${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}")"
  [ -n "$admin_conf_uuid" ] || fail "Could not resolve UUID for client '${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}'"
  assign_default_scope_to_client_if_missing  "$admin_conf_uuid" "acr"            "$SCOPE_ID_ACR"
  assign_default_scope_to_client_if_missing  "$admin_conf_uuid" "openid"         "$SCOPE_ID_OPENID"
  assign_default_scope_to_client_if_missing  "$admin_conf_uuid" "roles"          "$SCOPE_ID_ROLES"
  assign_optional_scope_to_client_if_missing "$admin_conf_uuid" "offline_access" "$SCOPE_ID_OFFLINE"

  log "Client scopes configured"
}

# ---------------------------------------------------------------------------
# Reconcile the public browser client's deployment-specific redirect settings.
# Realm import in bootstrap mode creates these values only on first install;
# this reconciliation keeps an existing client current on Helm upgrades.
# ---------------------------------------------------------------------------

configure_public_client_redirects() {
  log_section "Public client redirect configuration"

  client_uuid="$(get_client_uuid_by_client_id "${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}")"
  [ -n "$client_uuid" ] || fail "Could not resolve UUID for client '${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}'"

  client_json="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}")"
  updated_json="$(
    printf '%s' "$client_json" | jq \
      --arg redirect1 "${FORWARDMEASURE_ADMIN_PUBLIC_REDIRECT_URI_1}" \
      --arg redirect2 "${FORWARDMEASURE_ADMIN_PUBLIC_REDIRECT_URI_2}" \
      --argjson additionalRedirects "${FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_REDIRECT_URIS_JSON}" \
      --arg origin1 "${FORWARDMEASURE_ADMIN_PUBLIC_WEB_ORIGIN_1}" \
      --arg origin2 "${FORWARDMEASURE_ADMIN_PUBLIC_WEB_ORIGIN_2}" \
      --argjson additionalOrigins "${FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_WEB_ORIGINS_JSON}" \
      --arg logout "${FORWARDMEASURE_ADMIN_PUBLIC_POST_LOGOUT_REDIRECT_URIS}" \
      '.redirectUris = ([$redirect1, $redirect2] + $additionalRedirects | map(select(type == "string" and length > 0)) | unique)
       | .webOrigins = ([$origin1, $origin2] + $additionalOrigins | map(select(type == "string" and length > 0)) | unique)
       | .attributes["post.logout.redirect.uris"] = $logout'
  )"

  kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}" "$updated_json"
  log "Redirect URIs and web origins reconciled for client: ${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}"
}

configure_public_client_audiences() {
  log_section "Public client audience configuration"
  client_uuid="$(get_client_uuid_by_client_id "${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}")"
  [ -n "$client_uuid" ] || fail "Could not resolve UUID for client '${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}'"
  reconcile_client_audiences "$client_uuid" "${FORWARDMEASURE_ADMIN_PUBLIC_AUDIENCES_JSON}"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models")"
  printf '%s' "${FORWARDMEASURE_ADMIN_PUBLIC_AUDIENCES_JSON}" | jq -r '.[]' | while IFS= read -r audience; do
    mapper_name="hardcoded-audience:${audience}"
    if printf '%s' "$existing" | jq -e --arg name "$mapper_name" '.[] | select(.name == $name)' >/dev/null; then
      log "Audience mapper already exists: ${audience}"
      continue
    fi
    body="$(jq -n --arg name "$mapper_name" --arg audience "$audience" '{
      name: $name,
      protocol: "openid-connect",
      protocolMapper: "oidc-audience-mapper",
      consentRequired: false,
      config: {
        "included.custom.audience": $audience,
        "access.token.claim": "true",
        "id.token.claim": "false"
      }
    }')"
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" "$body"
    log "Created public-client audience mapper: ${audience}"
  done
}

ensure_client_audience() {
  client_uuid="$1"
  audience="$2"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models")"
  mapper_name="hardcoded-audience:${audience}"
  if printf '%s' "$existing" | jq -e --arg name "$mapper_name" '.[] | select(.name == $name)' >/dev/null; then
    return 0
  fi
  body="$(jq -n --arg name "$mapper_name" --arg audience "$audience" '{
    name: $name,
    protocol: "openid-connect",
    protocolMapper: "oidc-audience-mapper",
    consentRequired: false,
    config: {
      "included.custom.audience": $audience,
      "access.token.claim": "true",
      "id.token.claim": "false"
    }
  }')"
  kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" "$body"
}

reconcile_client_audiences() {
  client_uuid="$1"
  desired="$2"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models")"
  printf '%s' "$existing" | jq -c '.[] | select(.name | startswith("hardcoded-audience:"))' \
    | while IFS= read -r mapper; do
      mapper_id="$(printf '%s' "$mapper" | jq -r '.id')"
      audience="$(printf '%s' "$mapper" | jq -r '.config["included.custom.audience"] // empty')"
      if ! printf '%s' "$desired" | jq -e --arg audience "$audience" \
          'index($audience) != null' >/dev/null; then
        kc_delete_no_body "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models/${mapper_id}"
        log "Removed obsolete service-client audience mapper: ${audience}"
      fi
    done
}

ensure_client_hardcoded_claim() {
  client_uuid="$1"
  claim_name="$2"
  claim_value="$3"
  mapper_name="hardcoded-claim:${claim_name}"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models")"
  existing_mapper="$(printf '%s' "$existing" | jq -c --arg name "$mapper_name" '.[] | select(.name == $name)' | head -n 1)"
  body="$(jq -n \
    --arg name "$mapper_name" \
    --arg claim "$claim_name" \
    --arg value "$claim_value" '{
      name: $name,
      protocol: "openid-connect",
      protocolMapper: "oidc-hardcoded-claim-mapper",
      consentRequired: false,
      config: {
        "claim.name": $claim,
        "claim.value": $value,
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "userinfo.token.claim": "false"
      }
    }')"
  if [ -z "$existing_mapper" ]; then
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" "$body"
    return 0
  fi
  mapper_id="$(printf '%s' "$existing_mapper" | jq -r '.id')"
  if ! printf '%s' "$existing_mapper" | jq -e \
      --arg claim "$claim_name" --arg value "$claim_value" '
        .protocol == "openid-connect"
        and .protocolMapper == "oidc-hardcoded-claim-mapper"
        and .config["claim.name"] == $claim
        and .config["claim.value"] == $value
        and .config["jsonType.label"] == "String"
        and .config["access.token.claim"] == "true"
        and .config["id.token.claim"] == "false"
        and .config["userinfo.token.claim"] == "false"' >/dev/null; then
    body="$(printf '%s' "$body" | jq --arg id "$mapper_id" '.id = $id')"
    kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models/${mapper_id}" "$body"
  fi
  printf '%s' "$existing" | jq -r --arg name "$mapper_name" \
    '[.[] | select(.name == $name) | .id][1:][]' \
    | while IFS= read -r duplicate_id; do
      kc_delete_no_body "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models/${duplicate_id}"
      log "Removed duplicate service-client hardcoded claim mapper: ${claim_name}"
    done
}

reconcile_client_hardcoded_claims() {
  client_uuid="$1"
  desired="$2"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models")"
  printf '%s' "$existing" | jq -c '.[] | select(.name | startswith("hardcoded-claim:"))' \
    | while IFS= read -r mapper; do
      mapper_id="$(printf '%s' "$mapper" | jq -r '.id')"
      claim_name="$(printf '%s' "$mapper" | jq -r '.config["claim.name"] // empty')"
      if ! printf '%s' "$desired" | jq -e --arg claim "$claim_name" \
          'has($claim)' >/dev/null; then
        kc_delete_no_body "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models/${mapper_id}"
        log "Removed obsolete service-client hardcoded claim: ${claim_name}"
      fi
    done
}

reconcile_service_account_realm_roles() {
  user_id="$1"
  desired="$2"
  existing="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/realm")"
  printf '%s' "$existing" | jq -c '.[]' | while IFS= read -r role_json; do
    role_name="$(printf '%s' "$role_json" | jq -r '.name')"
    if ! printf '%s' "$desired" | jq -e --arg role "$role_name" \
        'index($role) != null' >/dev/null; then
      kc_delete_json \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/realm" \
        "[$role_json]"
      log "Removed obsolete service-account realm role: ${role_name}"
    fi
  done
}

configure_service_clients() {
  log_section "Least-privilege service clients"
  printf '%s' "${FORWARDMEASURE_SERVICE_CLIENTS_JSON}" | jq -e 'type == "array"' >/dev/null \
    || fail "FORWARDMEASURE_SERVICE_CLIENTS_JSON must be a JSON array"
  count="$(printf '%s' "${FORWARDMEASURE_SERVICE_CLIENTS_JSON}" | jq 'length')"
  index=0
  while [ "$index" -lt "$count" ]; do
    client="$(printf '%s' "${FORWARDMEASURE_SERVICE_CLIENTS_JSON}" | jq -c ".[$index]")"
    client_id="$(printf '%s' "$client" | jq -er '.clientId | select(type == "string" and length > 0)')" \
      || fail "serviceClients[$index].clientId is required"
    client_name="$(printf '%s' "$client" | jq -er '.name | select(type == "string" and length > 0)')" \
      || fail "serviceClients[$index].name is required"
    secret_key="$(printf '%s' "$client" | jq -er '.secretKey | select(type == "string" and test("^[A-Za-z0-9_.-]+$"))')" \
      || fail "serviceClients[$index].secretKey is invalid"
    secret_path="${FORWARDMEASURE_SERVICE_CLIENT_SECRETS_DIRECTORY}/${secret_key}"
    [ -f "$secret_path" ] || fail "Missing secret key '${secret_key}' for service client '${client_id}'"
    client_secret="$(cat "$secret_path")"
    [ -n "$client_secret" ] || fail "Secret key '${secret_key}' is empty"
    body="$(jq -n --arg id "$client_id" --arg name "$client_name" --arg secret "$client_secret" '{
      clientId: $id,
      name: $name,
      description: "Least-privilege ForwardMeasure workload client",
      enabled: true,
      protocol: "openid-connect",
      publicClient: false,
      bearerOnly: false,
      standardFlowEnabled: false,
      implicitFlowEnabled: false,
      directAccessGrantsEnabled: false,
      serviceAccountsEnabled: true,
      clientAuthenticatorType: "client-secret",
      secret: $secret
    }')"
    client_uuid="$(get_client_uuid_by_client_id "$client_id")"
    if [ -z "$client_uuid" ]; then
      kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" "$body"
      client_uuid="$(get_client_uuid_by_client_id "$client_id")"
    else
      existing_client="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}")"
      updated_client="$(printf '%s' "$existing_client" | jq --arg name "$client_name" --arg secret "$client_secret" '
        .name = $name
        | .enabled = true
        | .publicClient = false
        | .bearerOnly = false
        | .standardFlowEnabled = false
        | .implicitFlowEnabled = false
        | .directAccessGrantsEnabled = false
        | .serviceAccountsEnabled = true
        | .clientAuthenticatorType = "client-secret"
        | .secret = $secret')"
      kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}" "$updated_client"
    fi
    [ -n "$client_uuid" ] || fail "Could not reconcile service client '${client_id}'"
    assign_default_scope_to_client_if_missing "$client_uuid" "openid" "$SCOPE_ID_OPENID"
    assign_default_scope_to_client_if_missing "$client_uuid" "roles" "$SCOPE_ID_ROLES"
    service_user="$(get_service_account_user_id "$client_uuid")"
    [ -n "$service_user" ] || fail "No service account exists for '${client_id}'"
    role_count="$(printf '%s' "$client" | jq -er '(.realmRoles // []) | if type == "array" then length else error("realmRoles must be an array") end')" \
      || fail "serviceClients[$index].realmRoles must be an array"
    desired_roles="$(printf '%s' "$client" | jq -c '.realmRoles // []')"
    reconcile_service_account_realm_roles "$service_user" "$desired_roles"
    role_index=0
    while [ "$role_index" -lt "$role_count" ]; do
      role="$(printf '%s' "$client" | jq -er ".realmRoles[$role_index] | select(type == \"string\" and length > 0)")" \
        || fail "serviceClients[$index].realmRoles[$role_index] is invalid"
      ensure_realm_role "$role" "ForwardMeasure workload authorization role"
      assign_realm_role_to_user_if_missing "$service_user" "$role"
      role_index=$((role_index + 1))
    done
    audience_count="$(printf '%s' "$client" | jq -er '(.audiences // []) | if type == "array" then length else error("audiences must be an array") end')" \
      || fail "serviceClients[$index].audiences must be an array"
    desired_audiences="$(printf '%s' "$client" | jq -c '.audiences // []')"
    reconcile_client_audiences "$client_uuid" "$desired_audiences"
    audience_index=0
    while [ "$audience_index" -lt "$audience_count" ]; do
      audience="$(printf '%s' "$client" | jq -er ".audiences[$audience_index] | select(type == \"string\" and length > 0)")" \
        || fail "serviceClients[$index].audiences[$audience_index] is invalid"
      ensure_client_audience "$client_uuid" "$audience"
      audience_index=$((audience_index + 1))
    done
    claims="$(printf '%s' "$client" | jq -ec '
      (.claims // {})
      | if type == "object"
        then with_entries(
          if ((.key | test("^[A-Za-z][A-Za-z0-9_.-]*$"))
            and ((.key | test("^(iss|sub|aud|exp|iat|nbf|jti|azp)$")) | not)
            and (.value | type == "string" and length > 0))
          then .
          else error("claims must contain non-empty string values under safe, non-reserved claim names")
          end)
        else error("claims must be an object")
        end')" \
      || fail "serviceClients[$index].claims is invalid"
    reconcile_client_hardcoded_claims "$client_uuid" "$claims"
    printf '%s' "$claims" | jq -c 'to_entries[]' | while IFS= read -r claim; do
      claim_name="$(printf '%s' "$claim" | jq -r '.key')"
      claim_value="$(printf '%s' "$claim" | jq -r '.value')"
      ensure_client_hardcoded_claim "$client_uuid" "$claim_name" "$claim_value"
    done
    log "Service client reconciled: ${client_id}"
    unset client_secret
    index=$((index + 1))
  done
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

configure_platform_roles() {
  log_section "Phase 1: platform realm roles"
  ensure_realm_role "${FORWARDMEASURE_ROLE_VIEWER}"         "Read-only access to ForwardMeasure platform"
  ensure_realm_role "${FORWARDMEASURE_ROLE_ACCESS_ADMIN}"   "Manage users, roles, and access in ForwardMeasure"
  ensure_realm_role "${FORWARDMEASURE_ROLE_PLATFORM_ADMIN}" "Full administrative access to ForwardMeasure platform"
  ensure_composite_role "${FORWARDMEASURE_ROLE_PLATFORM_ADMIN}" "${FORWARDMEASURE_ROLE_VIEWER}"
  ensure_composite_role "${FORWARDMEASURE_ROLE_PLATFORM_ADMIN}" "${FORWARDMEASURE_ROLE_ACCESS_ADMIN}"
  log "Platform roles configured"
}

configure_services_roles() {
  log_section "Phase 1a: services realm roles"
  if [ -z "${FORWARDMEASURE_TENANT_GROUP_ROLES}" ]; then
    log "FORWARDMEASURE_TENANT_GROUP_ROLES is empty — skipping services roles"
    return 0
  fi
  OLD_IFS="$IFS"
  IFS=','
  for role in ${FORWARDMEASURE_TENANT_GROUP_ROLES}; do
    IFS="$OLD_IFS"
    trimmed="$(printf '%s' "$role" | tr -d '[:space:]')"
    [ -n "$trimmed" ] || continue
    ensure_realm_role "$trimmed" "ForwardMeasure tenant service role: ${trimmed}"
    IFS=','
  done
  IFS="$OLD_IFS"
  log "Services roles configured"
}

configure_bootstrap_user() {
  log_section "Phase 2: bootstrap admin user"
  create_or_update_bootstrap_user
  set_bootstrap_user_password
  assign_realm_role_to_user_if_missing "${BOOTSTRAP_USER_ID}" "${FORWARDMEASURE_ROLE_PLATFORM_ADMIN}"
  log "Bootstrap user configured"
}

# Keycloak auto-creates the "organization" client scope once
# organizationsEnabled=true on the realm, but the scope isn't attached to
# any client by default, and KeycloakOrganizationClaims.extract() (the
# fail-closed authorization-context reader every OpenWorkflow API call goes
# through) needs it on the token. Confirmed live: without this, a real
# user's token has no "organization" claim at all and every authorization
# check 500s with "organization claim is required".
#
# oidc-organization-group-membership-mapper (with addGroupRoleMappings) is
# what nests a user's org-scoped client roles into this same claim as
# KeycloakOrganizationClaims' "resource_access.{clientId}.roles" - it
# requires Keycloak 26.7+ (confirmed against 26.5: POST-ing it 404s
# "ProtocolMapper provider not found"; confirmed against 26.7.2: it's a
# registered provider, per /admin/serverinfo's protocol-mapper list).
configure_organization_claim() {
  log_section "Phase 3a: organization claim"
  scope_id="$(get_scope_id_by_name organization)"
  if [ -z "$scope_id" ]; then
    scope_id="$(ensure_client_scope "organization" '{"name":"organization","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}')"
  fi
  existing_mappers="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${scope_id}/protocol-mappers/models")"
  membership_mapper_id="$(printf '%s' "$existing_mappers" | jq -r '.[] | select(.protocolMapper=="oidc-organization-membership-mapper") | .id' | head -n1)"
  membership_body="$(jq -n --arg id "$membership_mapper_id" '{
    name: "organization", protocol: "openid-connect",
    protocolMapper: "oidc-organization-membership-mapper", consentRequired: false,
    config: {
      "id.token.claim": "true", "introspection.token.claim": "true", "access.token.claim": "true",
      "claim.name": "organization", "jsonType.label": "JSON", "multivalued": "true",
      "addOrganizationAttributes": "true", "addOrganizationId": "true"
    }
  } + (if $id != "" then {id: $id} else {} end)')"
  if [ -n "$membership_mapper_id" ]; then
    kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${scope_id}/protocol-mappers/models/${membership_mapper_id}" "$membership_body"
    log "Reconciled existing oidc-organization-membership-mapper (id=${membership_mapper_id})"
  else
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${scope_id}/protocol-mappers/models" "$membership_body"
    log "Created oidc-organization-membership-mapper"
  fi
  group_mapper_id="$(printf '%s' "$existing_mappers" | jq -r '.[] | select(.protocolMapper=="oidc-organization-group-membership-mapper") | .id' | head -n1)"
  group_body="$(jq -n --arg id "$group_mapper_id" '{
    name: "organization-group-membership", protocol: "openid-connect",
    protocolMapper: "oidc-organization-group-membership-mapper", consentRequired: false,
    config: {
      "id.token.claim": "true", "introspection.token.claim": "true", "access.token.claim": "true",
      "claim.name": "organization", "addGroupRoleMappings": "true"
    }
  } + (if $id != "" then {id: $id} else {} end)')"
  if [ -n "$group_mapper_id" ]; then
    kc_put_json "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${scope_id}/protocol-mappers/models/${group_mapper_id}" "$group_body"
    log "Reconciled existing oidc-organization-group-membership-mapper (id=${group_mapper_id})"
  else
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${scope_id}/protocol-mappers/models" "$group_body"
    log "Created oidc-organization-group-membership-mapper"
  fi
  admin_pub_uuid="$(get_client_uuid_by_client_id "${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}")"
  [ -n "$admin_pub_uuid" ] || fail "Could not resolve UUID for client '${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}'"
  assign_default_scope_to_client_if_missing "$admin_pub_uuid" "organization" "$scope_id"
  log "Organization claim configured for client: ${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}"
}

# TenantOrganizationReconciler (openworkflow-tenant-provisioning) creates the
# Organization itself plus its role groups, but deliberately never assigns
# any member - "Idempotently reconciles shared roles and tenant
# Organizations without assigning member roles" per its own class doc. This
# is the missing other half for one specific, already-known account: the
# bootstrap admin user this script maintains. Skips silently (not a failure)
# when the tenant alias/role env vars are unset, since most environments
# have no tenant Organization to join at all.
configure_tenant_organization_membership() {
  log_section "Phase 3b: tenant organization membership for bootstrap user"
  if [ -z "${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}" ]; then
    log "FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS is empty — skipping tenant organization membership"
    return 0
  fi
  encoded_query="$(printf 'alias:%s' "${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}" | jq -sRr @uri)"
  org_id="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations?q=${encoded_query}&briefRepresentation=false" \
    | jq -r --arg alias "${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}" '.[] | select(.alias==$alias) | .id' | head -n1)"
  [ -n "$org_id" ] || fail "No Organization with alias '${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}' — has tenant provisioning run for it yet?"

  log "Ensuring ${ADMIN_USERNAME} is a member of Organization '${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}' (id=${org_id})"
  existing_members="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/members" | jq -r '.[].id')"
  if printf '%s\n' "$existing_members" | grep -qx "${BOOTSTRAP_USER_ID}"; then
    log "${ADMIN_USERNAME} is already a member of Organization '${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}'"
  else
    # Not text/plain: confirmed live, that gets HTTP 415 "content-type
    # header value did not match @Consumes" - this endpoint wants the user
    # id as a bare JSON string.
    code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/members" \
      --data "$(json_escape "${BOOTSTRAP_USER_ID}")")"
    case "$code" in
      201 | 204 | 409) ;;
      *)
        cat /tmp/kc.out >&2 || true
        fail "POST organization member failed with HTTP ${code}"
        ;;
    esac
    log "${ADMIN_USERNAME} added as a member of Organization '${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}'"
  fi

  if [ -z "${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}" ]; then
    log "FORWARDMEASURE_TENANT_ORGANIZATION_ROLE is empty — skipping role-group membership"
    return 0
  fi
  # Genuine Keycloak Organization Groups (26.6+), NOT a top-level realm
  # Group merely named after the tenant alias. That was this function's
  # first version, written against HttpKeycloakOrganizationAdmin.java's own
  # comment that organizations/{id}/groups 404s - true on the Keycloak
  # version that comment was written against, confirmed NOT true on 26.7.2
  # (GET returns 200 []). Organization Groups have their own dedicated API
  # surface: the standard /groups/{id}/role-mappings/... and
  # /users/{id}/groups/{id} endpoints both reject them outright with
  # "Cannot manage/access organization related group via non Organization
  # API" (confirmed live, HTTP 400) - role-mappings and membership must go
  # through organizations/{orgId}/groups/{groupId}/... instead. This is also
  # why oidc-organization-group-membership-mapper's addGroupRoleMappings
  # finds nothing when a user is only in an unrelated same-named realm
  # group: it isn't reading realm groups, it's reading organization-scoped
  # ones.
  org_group_id="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/groups" \
    | jq -r --arg n "${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}" '.[] | select(.name==$n) | .id' | head -n1)"
  if [ -z "$org_group_id" ]; then
    log "Creating organization group '${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}' under Organization '${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}'"
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/groups" \
      "$(jq -n --arg name "${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}" '{name: $name}')"
    org_group_id="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/groups" \
      | jq -r --arg n "${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}" '.[] | select(.name==$n) | .id' | head -n1)"
  fi
  [ -n "$org_group_id" ] || fail "Could not create/resolve organization group '${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}' under '${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}'"

  admin_pub_uuid="$(get_client_uuid_by_client_id "${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}")"
  [ -n "$admin_pub_uuid" ] || fail "Could not resolve UUID for client '${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}'"
  org_group="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/groups/${org_group_id}")"
  has_role="$(printf '%s' "$org_group" | jq -r --arg client "${FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID}" --arg role "${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}" \
    '(.clientRoles[$client] // []) | index($role) != null')"
  if [ "$has_role" = "true" ]; then
    log "Organization group '${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}' already has client role mapped"
  else
    role_json="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${admin_pub_uuid}/roles/${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}")"
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/groups/${org_group_id}/role-mappings/clients/${admin_pub_uuid}" \
      "[$role_json]"
    log "Mapped client role '${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}' onto organization group"
  fi

  existing_group_members="$(kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/groups/${org_group_id}/members" | jq -r '.[].id')"
  if printf '%s\n' "$existing_group_members" | grep -qx "${BOOTSTRAP_USER_ID}"; then
    log "${ADMIN_USERNAME} already in organization group '${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}'"
  else
    kc_put_no_body "${KEYCLOAK_URL}/admin/realms/${REALM}/organizations/${org_id}/groups/${org_group_id}/members/${BOOTSTRAP_USER_ID}"
    log "${ADMIN_USERNAME} added to organization group '${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE}' under '${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS}'"
  fi
}

configure_admin_confidential_service_account() {
  log_section "Phase 3: admin confidential client service account"
  log "Resolving client uuid for: ${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}"
  admin_client_uuid="$(get_client_uuid_by_client_id "${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}")"
  [ -n "$admin_client_uuid" ] || fail "Could not resolve client uuid for '${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}'"
  log "Resolved client uuid: ${admin_client_uuid}"
  log "Resolving service account user for client: ${admin_client_uuid}"
  service_account_user_id="$(get_service_account_user_id "${admin_client_uuid}")"
  [ -n "$service_account_user_id" ] || fail "Could not resolve service account user for '${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}'"
  log "Resolved service account user id: ${service_account_user_id}"
  log "Resolving uuid for built-in client: realm-management"
  realm_mgmt_uuid="$(get_client_uuid_by_client_id "realm-management")"
  [ -n "$realm_mgmt_uuid" ] || fail "Could not resolve realm-management client uuid"
  log "Resolved realm-management uuid: ${realm_mgmt_uuid}"
  assign_realm_role_to_user_if_missing "${service_account_user_id}" "${FORWARDMEASURE_ROLE_PLATFORM_ADMIN}"
  assign_client_roles_to_user_if_missing "${service_account_user_id}" "${realm_mgmt_uuid}" "${KEYCLOAK_REALM_MGMT_ROLES}"
  log "Service account configured for: ${FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  KEYCLOAK_REALM_MGMT_ROLES="$(
    printf '%s' "${KEYCLOAK_REALM_MGMT_ROLES:-}" \
      | tr -d '[:space:]' \
      | sed 's/,\+/,/g; s/^,//; s/,$//'
  )"
  FORWARDMEASURE_TENANT_GROUP_ROLES="$(
    printf '%s' "${FORWARDMEASURE_TENANT_GROUP_ROLES:-}" \
      | tr -d '[:space:]' \
      | sed 's/,\+/,/g; s/^,//; s/,$//'
  )"

  require_env KEYCLOAK_URL
  require_env REALM
  require_env REALM_LOGIN_THEME
  require_env KEYCLOAK_ADMIN
  require_env KEYCLOAK_ADMIN_PASSWORD
  require_env ADMIN_USERNAME
  require_env ADMIN_EMAIL
  require_env ADMIN_FIRST_NAME
  require_env ADMIN_LAST_NAME
  require_env ADMIN_TENANT_DID
  require_env ADMIN_ACTOR_DID
  require_env ADMIN_ACTOR_TYPE
  require_env ADMIN_PASSWORD
  require_env FORWARDMEASURE_ROLE_VIEWER
  require_env FORWARDMEASURE_ROLE_ACCESS_ADMIN
  require_env FORWARDMEASURE_ROLE_PLATFORM_ADMIN
  require_env KEYCLOAK_REALM_MGMT_ROLES
  require_env FORWARDMEASURE_ADMIN_CONFIDENTIAL_CLIENT_ID
  require_env FORWARDMEASURE_ADMIN_PUBLIC_CLIENT_ID
  require_env FORWARDMEASURE_ADMIN_PUBLIC_REDIRECT_URI_1
  require_env FORWARDMEASURE_ADMIN_PUBLIC_REDIRECT_URI_2
  require_env FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_REDIRECT_URIS_JSON
  require_env FORWARDMEASURE_ADMIN_PUBLIC_WEB_ORIGIN_1
  require_env FORWARDMEASURE_ADMIN_PUBLIC_WEB_ORIGIN_2
  require_env FORWARDMEASURE_ADMIN_PUBLIC_ADDITIONAL_WEB_ORIGINS_JSON
  require_env FORWARDMEASURE_ADMIN_PUBLIC_POST_LOGOUT_REDIRECT_URIS
  require_env FORWARDMEASURE_ADMIN_PUBLIC_AUDIENCES_JSON
  require_env FORWARDMEASURE_SERVICE_CLIENTS_JSON
  require_env FORWARDMEASURE_SERVICE_CLIENT_SECRETS_DIRECTORY

  # All request paths below begin with "/". Normalise a configured root
  # context so URL joining never produces a Keycloak-rejected "//" path.
  KEYCLOAK_URL="${KEYCLOAK_URL%/}"

  : "${KEYCLOAK_READY_SLEEP_SECONDS:=5}"
  : "${KEYCLOAK_READY_MAX_ATTEMPTS:=60}"
  : "${FORWARDMEASURE_TENANT_ORGANIZATION_ALIAS:=}"
  : "${FORWARDMEASURE_TENANT_ORGANIZATION_ROLE:=}"

  print_config_banner
  wait_for_keycloak
  fetch_admin_token
  wait_for_realm_management_client
  configure_realm_theme
  configure_user_profile_unmanaged_attributes
  configure_platform_roles
  configure_services_roles
  configure_bootstrap_user
  configure_organization_claim
  configure_tenant_organization_membership
  configure_admin_confidential_service_account
  configure_client_scopes
  configure_service_clients
  configure_public_client_redirects
  configure_public_client_audiences

  log_section "Bootstrap provisioning complete"
}

main "$@"
