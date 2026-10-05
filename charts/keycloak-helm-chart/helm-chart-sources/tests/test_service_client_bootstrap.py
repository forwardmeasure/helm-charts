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
    *) echo "Unexpected tenant or Admin REST dependency: $1" >&2; exit 1 ;;
  esac
}
kc_put_json() { printf '%s\n' "$2" >> "$CAPTURE"; }
configure_service_clients
'''


class BootstrapTest(unittest.TestCase):
    def invoke(self, authz):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "TEST_SECRET").write_text("fixture-only-not-a-credential")
            script = SCRIPT.read_text().rsplit('main "$@"', 1)[0] + STUBS
            env = dict(os.environ, KEYCLOAK_URL="http://fixture.invalid", REALM="test",
                       SCOPE_ID_OPENID="openid", SCOPE_ID_ROLES="roles", CAPTURE=str(root / "calls"),
                       FORWARDMEASURE_SERVICE_CLIENT_SECRETS_DIRECTORY=str(root),
                       FORWARDMEASURE_SERVICE_CLIENTS_JSON=json.dumps([{
                           "clientId": "test-service", "name": "Test Service", "secretKey": "TEST_SECRET",
                           "authorizationServicesEnabled": authz, "organizationClaim": False}]))
            result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
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
