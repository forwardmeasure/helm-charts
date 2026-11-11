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

"""The real Admin REST session (login, renewal, one retry on a 401) against a local stand-in Keycloak.

The stand-in listens on 127.0.0.1 only and keeps a clock the test advances: tokens it issues expire by
that clock, as Keycloak's do by its own, so a call made with an expired token gets the 401 a real
server would send. Nothing leaves the machine and no container starts.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

SCRIPT = Path(__file__).parents[1] / "files/bootstrap-admin.sh"
ADMIN = "fixture-admin"
# Form-encoding characters on purpose: the login must send it exactly.
ADMIN_PASSWORD = "fixture only & not = a + credential %41"
CLIENT_SECRET = "fixture-client-secret-not-a-credential"


class StandInKeycloak:
    def __init__(self, clock_file):
        self.clock_file = clock_file
        self.lock = threading.Lock()
        self.expires_in = 60
        self.reject_logins = False
        self.revoked = set()
        self.revoke_after_first_use = False
        self.reject_every_token = False
        self.error_status = None
        self.error_body = None
        self.tokens = {}
        self.logins = []
        self.calls = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body=None):
                payload = b"" if body is None else json.dumps(body).encode()
                self.send_response(status)
                if payload:
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def body(self):
                return self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()

            def do_POST(self):
                if self.path == "/realms/master/protocol/openid-connect/token":
                    self.reply(*server.login(parse_qs(self.body(), keep_blank_values=True)))
                else:
                    self.reply(*server.admin("POST", self.path, self.headers, self.body()))

            def do_GET(self):
                self.reply(*server.admin("GET", self.path, self.headers, ""))

            def do_PUT(self):
                self.reply(*server.admin("PUT", self.path, self.headers, self.body()))

            def do_DELETE(self):
                self.reply(*server.admin("DELETE", self.path, self.headers, self.body()))

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def now(self):
        return int(Path(self.clock_file).read_text().strip())

    def login(self, form):
        with self.lock:
            fields = {key: values[0] for key, values in form.items()}
            self.logins.append({key: value for key, value in fields.items() if key != "password"})
            if self.reject_logins or fields != {"grant_type": "password", "client_id": "admin-cli",
                                                "username": ADMIN, "password": ADMIN_PASSWORD}:
                return 401, {"error": "invalid_grant", "error_description": "Invalid user credentials"}
            token = f"issued-access-token-{len(self.logins)}"
            self.tokens[token] = self.now() + self.expires_in
            return 200, {"access_token": token, "expires_in": self.expires_in,
                         "refresh_token": f"issued-refresh-token-{len(self.logins)}",
                         "refresh_expires_in": 1800, "token_type": "Bearer"}

    def admin(self, method, path, headers, body):
        with self.lock:
            authorization = headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ")
            valid = (authorization.startswith("Bearer ") and token in self.tokens
                     and self.now() < self.tokens[token] and token not in self.revoked
                     and not self.reject_every_token)
            status, reply = (401, {"error": "HTTP 401 Unauthorized"}) if not valid else self.route(method, path)
            self.calls.append({"method": method, "path": path, "token": token, "body": body, "status": status})
            if valid and self.revoke_after_first_use:
                self.revoked.add(token)
            return status, reply

    def route(self, method, path):
        if self.error_status is not None:
            return self.error_status, self.error_body
        url = urlsplit(path)
        if method == "GET" and url.path == "/admin/realms/test/clients":
            client_id = parse_qs(url.query)["clientId"][0]
            return 200, [{"id": f"uuid-of-{client_id}", "clientId": client_id}]
        if method == "PUT":
            return 204, None
        return 404, {"error": "Not Found"}

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class AdminSessionTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.clock = self.root / "clock"
        self.clock.write_text("1000")
        self.keycloak = StandInKeycloak(self.clock)
        self.addCleanup(self.keycloak.close)

    def run_job(self, driver, body=""):
        # The functions of the real script, its entry point cut off; only the clock is the test's.
        script = SCRIPT.read_text().rsplit('main "$@"', 1)[0] + r'''
kc_epoch_seconds() { cat "$CLOCK"; }
advance_clock_to() { printf '%s' "$1" > "$CLOCK"; }
clients_url() { printf '%s/admin/realms/test/clients?clientId=%s' "$KEYCLOAK_URL" "$1"; }
start_job_session
''' + driver
        env = dict(os.environ, KEYCLOAK_URL=self.keycloak.url, REALM="test", KEYCLOAK_ADMIN=ADMIN,
                   KEYCLOAK_ADMIN_PASSWORD=ADMIN_PASSWORD, CLOCK=str(self.clock),
                   MARKER=str(self.root / "continued"), BODY=body)
        result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        for secret in [ADMIN_PASSWORD, CLIENT_SECRET, *self.keycloak.tokens,
                       *(f"issued-refresh-token-{n}" for n in range(1, len(self.keycloak.logins) + 1))]:
            self.assertNotIn(secret, output)
        return result

    def tokens_used(self):
        return [call["token"] for call in self.keycloak.calls]

    def test_token_is_renewed_before_it_expires_without_a_401(self):
        result = self.run_job(r'''
kc_admin_login
kc_get "$(clients_url first)" >/dev/null
advance_clock_to 1044
kc_get "$(clients_url second)" >/dev/null
advance_clock_to 1046
kc_get "$(clients_url third)" >/dev/null
''')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(2, len(self.keycloak.logins))
        self.assertEqual(["issued-access-token-1", "issued-access-token-1", "issued-access-token-2"],
                         self.tokens_used())
        self.assertEqual([200, 200, 200], [call["status"] for call in self.keycloak.calls])
        self.assertIn("Admin access token is due for renewal", result.stderr)

    def test_a_token_renewed_inside_a_command_substitution_is_the_one_the_caller_uses(self):
        result = self.run_job(r'''
kc_admin_login
advance_clock_to 1050
uuid="$(kc_get "$(clients_url first)" | jq -r '.[0].id')"
[ "$uuid" = "uuid-of-first" ] || fail "unexpected uuid ${uuid}"
kc_put_json "${KEYCLOAK_URL}/admin/realms/test/clients/${uuid}" '{"name":"first"}'
''')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(2, len(self.keycloak.logins))
        self.assertEqual(["issued-access-token-2", "issued-access-token-2"], self.tokens_used())

    def test_a_401_renews_the_token_once_and_retries_that_call_once(self):
        self.keycloak.expires_in = 300
        self.keycloak.revoke_after_first_use = True
        body = json.dumps({"clientId": "first", "secret": CLIENT_SECRET})
        result = self.run_job(r'''
kc_get "$(clients_url first)" >/dev/null
kc_put_json "${KEYCLOAK_URL}/admin/realms/test/clients/uuid-of-first" "$BODY"
''', body)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(2, len(self.keycloak.logins))
        self.assertEqual([("GET", 200, "issued-access-token-1"), ("PUT", 401, "issued-access-token-1"),
                          ("PUT", 204, "issued-access-token-2")],
                         [(c["method"], c["status"], c["token"]) for c in self.keycloak.calls])
        self.assertEqual([body, body], [c["body"] for c in self.keycloak.calls[1:]])
        self.assertIn("-> HTTP 401", result.stderr)
        self.assertIn("retrying this call once", result.stderr)

    def test_a_second_401_ends_the_job_with_the_call_status_and_body_even_inside_a_pipeline(self):
        self.keycloak.reject_every_token = True
        result = self.run_job(r'''
uuid="$(kc_get "$(clients_url first)" | jq -r '.[0].id // empty')"
printf '%s' "continued with '${uuid}'" > "$MARKER"
''')
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "continued").exists(), "the job carried on after the failed call")
        self.assertEqual(2, len(self.keycloak.logins))
        self.assertEqual([401, 401], [call["status"] for call in self.keycloak.calls])
        self.assertIn(f"ERROR GET {self.keycloak.url}/admin/realms/test/clients?clientId=first -> HTTP 401: "
                      '{"error":"HTTP 401 Unauthorized"}', result.stderr)

    def test_a_rejected_login_ends_the_job_with_the_call_status_and_body(self):
        self.keycloak.reject_logins = True
        result = self.run_job(r'''
kc_admin_login
printf continued > "$MARKER"
''')
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "continued").exists())
        self.assertIn(f"ERROR POST {self.keycloak.url}/realms/master/protocol/openid-connect/token "
                      f"(admin login as {ADMIN}) -> HTTP 401: "
                      '{"error":"invalid_grant","error_description":"Invalid user credentials"}',
                      result.stderr)

    def test_an_unexpected_status_ends_the_job_with_secrets_redacted_from_the_body(self):
        self.keycloak.error_status = 400
        self.keycloak.error_body = {"errorMessage": "Client secret is invalid", "secret": CLIENT_SECRET,
                                    "nested": {"access_token": "issued-access-token-1"}}
        body = json.dumps({"clientId": "first", "secret": CLIENT_SECRET})
        result = self.run_job(r'''
kc_put_json "${KEYCLOAK_URL}/admin/realms/test/clients/uuid-of-first" "$BODY"
printf continued > "$MARKER"
''', body)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "continued").exists())
        self.assertEqual(1, len(self.keycloak.calls))
        self.assertIn(f"ERROR PUT {self.keycloak.url}/admin/realms/test/clients/uuid-of-first -> HTTP 400: "
                      '{"errorMessage":"Client secret is invalid","secret":"<redacted>",'
                      '"nested":{"access_token":"<redacted>"}}', result.stderr)

    def test_a_401_while_waiting_for_realm_management_renews_and_continues(self):
        self.keycloak.expires_in = 300
        self.keycloak.revoke_after_first_use = True
        result = self.run_job(r'''
KEYCLOAK_READY_MAX_ATTEMPTS=1
KEYCLOAK_READY_SLEEP_SECONDS=0
kc_get "$(clients_url first)" >/dev/null
wait_for_realm_management_client
''')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([200, 401, 200], [call["status"] for call in self.keycloak.calls])
        self.assertIn("realm-management client is visible (uuid=uuid-of-realm-management)", result.stderr)


if __name__ == "__main__":
    unittest.main()
