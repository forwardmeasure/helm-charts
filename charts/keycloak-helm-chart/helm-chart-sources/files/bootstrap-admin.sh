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
  if [ "$code" != "201" ] && [ "$code" != "204" ]; then
    cat /tmp/kc.out >&2 || true
    fail "POST $url failed with HTTP $code"
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

# kc_put_no_body — for scope assignment endpoints that take no request body
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

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

print_config_banner() {
  log_section "Bootstrap configuration"
  log "KEYCLOAK_URL              = ${KEYCLOAK_URL}"
  log "REALM                     = ${REALM}"
  log "KEYCLOAK_ADMIN            = ${KEYCLOAK_ADMIN}"
  log "ADMIN_USERNAME            = ${ADMIN_USERNAME}"
  log "ADMIN_EMAIL               = ${ADMIN_EMAIL}"
  log "ADMIN_FIRST_NAME          = ${ADMIN_FIRST_NAME}"
  log "ADMIN_LAST_NAME           = ${ADMIN_LAST_NAME}"
  log "DATAFABRIC_ROLE_VIEWER    = ${DATAFABRIC_ROLE_VIEWER}"
  log "DATAFABRIC_ROLE_ACCESS_ADMIN   = ${DATAFABRIC_ROLE_ACCESS_ADMIN}"
  log "DATAFABRIC_ROLE_PLATFORM_ADMIN = ${DATAFABRIC_ROLE_PLATFORM_ADMIN}"
  log "DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID = ${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}"
  log "KEYCLOAK_REALM_MGMT_ROLES = ${KEYCLOAK_REALM_MGMT_ROLES}"
  log "KEYCLOAK_READY_SLEEP_SECONDS = ${KEYCLOAK_READY_SLEEP_SECONDS}"
  log "KEYCLOAK_READY_MAX_ATTEMPTS  = ${KEYCLOAK_READY_MAX_ATTEMPTS}"
  log_section "Starting bootstrap"
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

  if [ -z "$user_id" ]; then
    log "Bootstrap user not found — creating: ${ADMIN_USERNAME}"
    kc_post_json "${KEYCLOAK_URL}/admin/realms/${REALM}/users" "$user_body"

    # Keycloak user-search indexing is async — retry the lookup
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
#
# Keycloak built-in client scopes (roles, profile, email, web-origins, acr,
# openid, address, phone, microprofile-jwt) are normally created automatically
# when a realm is initialised. However when a realm is imported with
# OVERWRITE_EXISTING these built-ins are wiped and only the scopes defined in
# the import JSON survive. This phase recreates any missing built-in scopes
# with their standard protocol mappers, then assigns the correct default and
# optional scopes to each client — idempotently.
# ---------------------------------------------------------------------------

# Returns the UUID of a client scope by name, or empty string if not found.
# tr strips the trailing newline that jq -r always appends, which would
# otherwise be embedded in URLs and cause curl to reject them.
get_scope_id_by_name() {
  scope_name="$1"
  kc_get "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    | jq -r --arg n "$scope_name" '.[] | select(.name==$n) | .id' \
    | tr -d '\n'
}

# Creates a client scope if it doesn't already exist, then returns its UUID.
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
  # POST returns 201 with a Location header but no body — fetch UUID after
  code="$(curl -sS -o /tmp/kc.out -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    --data "$scope_body")"
  if [ "$code" != "201" ]; then
    cat /tmp/kc.out >&2 || true
    fail "POST client-scope '${scope_name}' failed with HTTP $code"
  fi

  new_id="$(get_scope_id_by_name "$scope_name")"
  [ -n "$new_id" ] || fail "Created scope '${scope_name}' but could not retrieve its UUID"
  log "Created client scope: ${scope_name} (id=${new_id})"
  printf '%s' "$new_id"
}

# Assigns a scope as a default scope on a client if not already present.
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

# Assigns a scope as an optional scope on a client if not already present.
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
#
# These replicate exactly what Keycloak creates automatically at realm init.
# Each function ensures the scope + its protocol mappers exist, and returns
# the scope UUID via stdout.
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

  # Ensure every built-in scope exists, capturing UUIDs
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
  SCOPE_ID_TENANT="$(get_scope_id_by_name "tenant_details")"

  [ -n "$SCOPE_ID_OFFLINE" ] || fail "Could not find scope 'offline_access' — realm import may have failed"
  [ -n "$SCOPE_ID_TENANT"  ] || fail "Could not find scope 'tenant_details' — realm import may have failed"

  log "All client scopes verified"

  # ------------------------------------------------------------------
  # datafabric-public
  # default:   web-origins, roles, profile, email, acr, openid, tenant_details
  # optional:  address, phone, offline_access
  # ------------------------------------------------------------------
  log "Configuring scopes for client: ${DATAFABRIC_PUBLIC_CLIENT_ID}"
  pub_uuid="$(get_client_uuid_by_client_id "${DATAFABRIC_PUBLIC_CLIENT_ID}")"
  [ -n "$pub_uuid" ] || fail "Could not resolve UUID for client '${DATAFABRIC_PUBLIC_CLIENT_ID}'"

  assign_default_scope_to_client_if_missing  "$pub_uuid" "web-origins"    "$SCOPE_ID_WEB_ORIGINS"
  assign_default_scope_to_client_if_missing  "$pub_uuid" "roles"           "$SCOPE_ID_ROLES"
  assign_default_scope_to_client_if_missing  "$pub_uuid" "profile"         "$SCOPE_ID_PROFILE"
  assign_default_scope_to_client_if_missing  "$pub_uuid" "email"           "$SCOPE_ID_EMAIL"
  assign_default_scope_to_client_if_missing  "$pub_uuid" "acr"             "$SCOPE_ID_ACR"
  assign_default_scope_to_client_if_missing  "$pub_uuid" "openid"          "$SCOPE_ID_OPENID"
  assign_default_scope_to_client_if_missing  "$pub_uuid" "tenant_details"  "$SCOPE_ID_TENANT"
  assign_optional_scope_to_client_if_missing "$pub_uuid" "address"         "$SCOPE_ID_ADDRESS"
  assign_optional_scope_to_client_if_missing "$pub_uuid" "phone"           "$SCOPE_ID_PHONE"
  assign_optional_scope_to_client_if_missing "$pub_uuid" "offline_access"  "$SCOPE_ID_OFFLINE"

  # ------------------------------------------------------------------
  # datafabric-confidential (default service-to-service client)
  # default:   roles, acr, openid, tenant_details
  # optional:  offline_access
  # ------------------------------------------------------------------
  log "Configuring scopes for client: ${DATAFABRIC_DEFAULT_CONFIDENTIAL_CLIENT_ID}"
  conf_uuid="$(get_client_uuid_by_client_id "${DATAFABRIC_DEFAULT_CONFIDENTIAL_CLIENT_ID}")"
  [ -n "$conf_uuid" ] || fail "Could not resolve UUID for client '${DATAFABRIC_DEFAULT_CONFIDENTIAL_CLIENT_ID}'"

  assign_default_scope_to_client_if_missing  "$conf_uuid" "roles"          "$SCOPE_ID_ROLES"
  assign_default_scope_to_client_if_missing  "$conf_uuid" "acr"            "$SCOPE_ID_ACR"
  assign_default_scope_to_client_if_missing  "$conf_uuid" "openid"         "$SCOPE_ID_OPENID"
  assign_default_scope_to_client_if_missing  "$conf_uuid" "tenant_details" "$SCOPE_ID_TENANT"
  assign_optional_scope_to_client_if_missing "$conf_uuid" "offline_access" "$SCOPE_ID_OFFLINE"

  # ------------------------------------------------------------------
  # datafabric-admin-public
  # default:   web-origins, roles, profile, email, acr, openid
  # optional:  address, phone, offline_access
  # ------------------------------------------------------------------
  log "Configuring scopes for client: ${DATAFABRIC_ADMIN_PUBLIC_CLIENT_ID}"
  admin_pub_uuid="$(get_client_uuid_by_client_id "${DATAFABRIC_ADMIN_PUBLIC_CLIENT_ID}")"
  [ -n "$admin_pub_uuid" ] || fail "Could not resolve UUID for client '${DATAFABRIC_ADMIN_PUBLIC_CLIENT_ID}'"

  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "web-origins"   "$SCOPE_ID_WEB_ORIGINS"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "roles"          "$SCOPE_ID_ROLES"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "profile"        "$SCOPE_ID_PROFILE"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "email"          "$SCOPE_ID_EMAIL"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "acr"            "$SCOPE_ID_ACR"
  assign_default_scope_to_client_if_missing  "$admin_pub_uuid" "openid"         "$SCOPE_ID_OPENID"
  assign_optional_scope_to_client_if_missing "$admin_pub_uuid" "address"        "$SCOPE_ID_ADDRESS"
  assign_optional_scope_to_client_if_missing "$admin_pub_uuid" "phone"          "$SCOPE_ID_PHONE"
  assign_optional_scope_to_client_if_missing "$admin_pub_uuid" "offline_access" "$SCOPE_ID_OFFLINE"

  # ------------------------------------------------------------------
  # datafabric-admin-confidential
  # default:   roles, acr, openid
  # optional:  offline_access
  # ------------------------------------------------------------------
  log "Configuring scopes for client: ${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}"
  admin_conf_uuid="$(get_client_uuid_by_client_id "${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}")"
  [ -n "$admin_conf_uuid" ] || fail "Could not resolve UUID for client '${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}'"

  assign_default_scope_to_client_if_missing  "$admin_conf_uuid" "roles"          "$SCOPE_ID_ROLES"
  assign_default_scope_to_client_if_missing  "$admin_conf_uuid" "acr"            "$SCOPE_ID_ACR"
  assign_default_scope_to_client_if_missing  "$admin_conf_uuid" "openid"         "$SCOPE_ID_OPENID"
  assign_optional_scope_to_client_if_missing "$admin_conf_uuid" "offline_access" "$SCOPE_ID_OFFLINE"

  log "Client scopes configured"
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

configure_platform_roles() {
  log_section "Phase 1: platform realm roles"
  ensure_realm_role "${DATAFABRIC_ROLE_VIEWER}"         "Read-only access to Data Fabric platform"
  ensure_realm_role "${DATAFABRIC_ROLE_ACCESS_ADMIN}"   "Manage users, roles, and access in Data Fabric"
  ensure_realm_role "${DATAFABRIC_ROLE_PLATFORM_ADMIN}" "Full administrative access to Data Fabric platform"
  ensure_composite_role "${DATAFABRIC_ROLE_PLATFORM_ADMIN}" "${DATAFABRIC_ROLE_VIEWER}"
  ensure_composite_role "${DATAFABRIC_ROLE_PLATFORM_ADMIN}" "${DATAFABRIC_ROLE_ACCESS_ADMIN}"
  log "Platform roles configured"
}

configure_bootstrap_user() {
  log_section "Phase 2: bootstrap admin user"
  create_or_update_bootstrap_user
  set_bootstrap_user_password
  assign_realm_role_to_user_if_missing "${BOOTSTRAP_USER_ID}" "${DATAFABRIC_ROLE_PLATFORM_ADMIN}"
  log "Bootstrap user configured"
}

configure_admin_confidential_service_account() {
  log_section "Phase 3: admin confidential client service account"

  log "Resolving client uuid for: ${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}"
  admin_client_uuid="$(get_client_uuid_by_client_id "${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}")"
  [ -n "$admin_client_uuid" ] || fail "Could not resolve client uuid for '${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}'"
  log "Resolved client uuid: ${admin_client_uuid}"

  log "Resolving service account user for client: ${admin_client_uuid}"
  service_account_user_id="$(get_service_account_user_id "${admin_client_uuid}")"
  [ -n "$service_account_user_id" ] || fail "Could not resolve service account user for '${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}'"
  log "Resolved service account user id: ${service_account_user_id}"

  log "Resolving uuid for built-in client: realm-management"
  realm_mgmt_uuid="$(get_client_uuid_by_client_id "realm-management")"
  [ -n "$realm_mgmt_uuid" ] || fail "Could not resolve realm-management client uuid"
  log "Resolved realm-management uuid: ${realm_mgmt_uuid}"

  assign_realm_role_to_user_if_missing "${service_account_user_id}" "${DATAFABRIC_ROLE_PLATFORM_ADMIN}"
  assign_client_roles_to_user_if_missing "${service_account_user_id}" "${realm_mgmt_uuid}" "${KEYCLOAK_REALM_MGMT_ROLES}"

  log "Service account configured for: ${DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  # Sanitise KEYCLOAK_REALM_MGMT_ROLES: YAML folded scalars (>) replace
  # newlines with spaces. Normalise to clean comma-separated list.
  KEYCLOAK_REALM_MGMT_ROLES="$(
    printf '%s' "${KEYCLOAK_REALM_MGMT_ROLES:-}" \
      | tr -d '[:space:]' \
      | sed 's/,\+/,/g; s/^,//; s/,$//'
  )"

  require_env KEYCLOAK_URL
  require_env REALM
  require_env KEYCLOAK_ADMIN
  require_env KEYCLOAK_ADMIN_PASSWORD
  require_env ADMIN_USERNAME
  require_env ADMIN_EMAIL
  require_env ADMIN_FIRST_NAME
  require_env ADMIN_LAST_NAME
  require_env ADMIN_PASSWORD
  require_env DATAFABRIC_ROLE_VIEWER
  require_env DATAFABRIC_ROLE_ACCESS_ADMIN
  require_env DATAFABRIC_ROLE_PLATFORM_ADMIN
  require_env KEYCLOAK_REALM_MGMT_ROLES
  require_env DATAFABRIC_ADMIN_CONFIDENTIAL_CLIENT_ID
  require_env DATAFABRIC_PUBLIC_CLIENT_ID
  require_env DATAFABRIC_DEFAULT_CONFIDENTIAL_CLIENT_ID
  require_env DATAFABRIC_ADMIN_PUBLIC_CLIENT_ID

  : "${KEYCLOAK_READY_SLEEP_SECONDS:=5}"
  : "${KEYCLOAK_READY_MAX_ATTEMPTS:=60}"

  print_config_banner
  wait_for_keycloak
  fetch_admin_token
  configure_platform_roles
  configure_bootstrap_user
  configure_admin_confidential_service_account
  configure_client_scopes

  log_section "Bootstrap provisioning complete"
}

main "$@"