"""Exercise the real tenant-administrator bootstrap against recorded Admin REST responses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / "files/bootstrap-admin.sh"
STUBS = r'''
kc_get() {
  case "$1" in
    */users\?username=pn\&exact=true)
      if [ -n "${EXISTING_USER:-}" ] || [ -s "$CAPTURE" ]; then
        printf '%s' '[{"id":"fixture-user"}]'
      else
        printf '%s' '[]'
      fi ;;
    *) echo "Unexpected Admin REST dependency: $1" >&2; exit 1 ;;
  esac
}
kc_post_json() { printf 'POST %s %s\n' "$1" "$(printf '%s' "$2" | jq -c .)" >> "$CAPTURE"; }
kc_put_json() { printf 'PUT %s %s\n' "$1" "$(printf '%s' "$2" | jq -c .)" >> "$CAPTURE"; }
assign_realm_role_to_user_if_missing() { echo "unexpected realm role $2" >&2; exit 1; }
configure_tenant_administrators
'''

ADMINISTRATOR = {
    "username": "pn", "email": "pn+justice@example.test", "firstName": "Prashanth",
    "lastName": "Nandavanam", "tenantDid": "did:web:justice.example.test",
    "actorDid": "did:web:justice.example.test:actors:pn", "actorType": "HUMAN",
    "passwordKey": "justice-pn",
}


class TenantAdministratorBootstrapTest(unittest.TestCase):
    def invoke(self, administrators, existing=False, password="fixture-only-not-a-credential"):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            if password is not None:
                (root / "justice-pn").write_text(password + "\n")
            script = SCRIPT.read_text().rsplit('main "$@"', 1)[0] + STUBS
            env = dict(os.environ, KEYCLOAK_URL="http://fixture.invalid", REALM="test",
                       CAPTURE=str(root / "calls"), EXISTING_USER="yes" if existing else "",
                       FORWARDMEASURE_TENANT_ADMINISTRATORS_JSON=json.dumps(administrators),
                       FORWARDMEASURE_TENANT_ADMINISTRATOR_PASSWORDS_DIRECTORY=str(root))
            result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
            return result, calls.splitlines()

    @staticmethod
    def body(line):
        return json.loads(line.split(" ", 2)[2])

    def test_a_new_administrator_is_created_with_a_temporary_password_and_no_platform_role(self):
        result, calls = self.invoke([ADMINISTRATOR])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, len(calls), calls)
        self.assertTrue(calls[0].startswith("POST http://fixture.invalid/admin/realms/test/users "))
        body = self.body(calls[0])
        self.assertEqual("pn", body["username"])
        self.assertEqual(["did:web:justice.example.test"], body["attributes"]["tenant_did"])
        self.assertEqual(["did:web:justice.example.test:actors:pn"], body["attributes"]["actor_did"])
        self.assertEqual(
            [{"type": "password", "value": "fixture-only-not-a-credential", "temporary": True}],
            body["credentials"])

    def test_an_existing_administrator_keeps_the_password_they_chose(self):
        result, calls = self.invoke([ADMINISTRATOR], existing=True, password=None)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, len(calls), calls)
        self.assertTrue(calls[0].startswith("PUT http://fixture.invalid/admin/realms/test/users/fixture-user "))
        body = self.body(calls[0])
        self.assertNotIn("credentials", body)
        self.assertEqual("Nandavanam", body["lastName"])

    def test_a_new_administrator_without_an_initial_password_fails(self):
        result, calls = self.invoke([ADMINISTRATOR], password=None)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], calls)

    def test_no_administrators_touch_nothing(self):
        result, calls = self.invoke([])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], calls)


if __name__ == "__main__":
    unittest.main()
