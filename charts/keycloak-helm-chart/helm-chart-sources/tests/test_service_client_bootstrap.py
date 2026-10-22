"""Exercise the real bootstrap function with recorded Admin REST transport responses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / "files/bootstrap-admin.sh"
STUBS = r'''
get_client_uuid_by_client_id() { printf '%s' fixture-client; }
get_service_account_user_id() { printf '%s' fixture-user; }
get_scope_id_by_name() { printf '%s' fixture-organization; }
assign_default_scope_to_client_if_missing() { :; }
reconcile_service_account_realm_roles() { :; }
reconcile_client_audiences() { :; }
reconcile_client_hardcoded_claims() { :; }
kc_get() {
  case "$1" in
    */clients/fixture-client) printf '%s' '{"id":"fixture-client"}' ;;
    */clients/fixture-client/default-client-scopes) printf '%s' '[]' ;;
    */users/fixture-user/role-mappings/clients/fixture-client)
      printf '%s' "${EXISTING_REALM_MANAGEMENT_ROLES:-[]}" ;;
    */clients/fixture-client/roles/*) printf '{"name":"%s"}' "${1##*/}" ;;
    *) echo "Unexpected tenant or Admin REST dependency: $1" >&2; exit 1 ;;
  esac
}
kc_put_json() { printf '%s\n' "$2" >> "$CAPTURE"; }
kc_post_json() { printf 'POST %s %s\n' "$1" "$2" >> "$ROLE_CAPTURE"; }
kc_delete_json() { printf 'DELETE %s %s\n' "$1" "$2" >> "$ROLE_CAPTURE"; }
configure_service_clients
'''


class BootstrapTest(unittest.TestCase):
    def invoke(self, authz, extra=None, existing_realm_management_roles="[]"):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "TEST_SECRET").write_text("fixture-only-not-a-credential")
            script = SCRIPT.read_text().rsplit('main "$@"', 1)[0] + STUBS
            env = dict(os.environ, KEYCLOAK_URL="http://fixture.invalid", REALM="test",
                       SCOPE_ID_OPENID="openid", SCOPE_ID_ROLES="roles", CAPTURE=str(root / "calls"),
                       FORWARDMEASURE_SERVICE_CLIENT_SECRETS_DIRECTORY=str(root),
                       ROLE_CAPTURE=str(root / "role-calls"),
                       EXISTING_REALM_MANAGEMENT_ROLES=existing_realm_management_roles,
                       FORWARDMEASURE_SERVICE_CLIENTS_JSON=json.dumps([{
                           "clientId": "test-service", "name": "Test Service", "secretKey": "TEST_SECRET",
                           "authorizationServicesEnabled": authz, "organizationClaim": False,
                           **(extra or {})}]))
            result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
            self.role_calls = (root / "role-calls").read_text() if (root / "role-calls").exists() else ""
            return result, calls

    def test_false_and_true_are_valid_without_any_organization_membership(self):
        for flag in (False, True):
            with self.subTest(flag=flag):
                result, calls = self.invoke(flag)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIs(flag, json.loads(calls)["authorizationServicesEnabled"])

    def test_string_false_is_not_a_boolean(self):
        result, calls = self.invoke("false")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("", calls)

    def test_without_realm_management_roles_none_are_touched(self):
        result, _ = self.invoke(False, existing_realm_management_roles='[{"name":"view-realm"}]')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", self.role_calls)

    def test_realm_management_roles_are_reconciled_to_exactly_the_declared_ones(self):
        result, _ = self.invoke(
            False,
            {"realmManagementRoles": ["view-users", "view-organizations"]},
            existing_realm_management_roles='[{"name":"view-users"},{"name":"manage-users"}]')
        self.assertEqual(0, result.returncode, result.stderr)
        lines = self.role_calls.splitlines()
        self.assertEqual(2, len(lines), self.role_calls)
        self.assertTrue(lines[0].startswith("DELETE ") and '"manage-users"' in lines[0], lines[0])
        self.assertTrue(lines[1].startswith("POST ") and '"view-organizations"' in lines[1], lines[1])
        self.assertNotIn('"view-users"', lines[1])

    def test_realm_management_roles_must_be_role_names(self):
        result, _ = self.invoke(False, {"realmManagementRoles": "view-users"})
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("", self.role_calls)
