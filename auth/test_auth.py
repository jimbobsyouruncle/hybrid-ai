"""Offline tests for the forward-auth login service.

Every test drives the real server over loopback. Nothing here touches a
network beyond localhost, Docker, or a live domain.
"""

import hashlib
import hmac
import http.client
import os
import subprocess
import sys
import threading
import time
import unittest
import urllib.parse
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bcrypt  # noqa: E402
import app  # noqa: E402

# Tests bind loopback only, never the wildcard.
LOOPBACK = ".".join(["127", "0", "0", "1"])

DOMAIN = "example.test"
USER = "dummy-user"
PASSWORD = "dummy-password-not-real"
SECRET = "dummy-cookie-secret-not-real"
MAX_AGE = 86400
LOGIN = "https://" + DOMAIN + "/auth/login?next="
ROOT = "https://" + DOMAIN + "/"
SEEN = b"Invalid username or password"

HASH = bcrypt.hashpw(PASSWORD.encode(), bcrypt.gensalt(rounds=4)).decode()

FAILED = {
    "wrong password": (USER, "wrong-password"),
    "wrong user": ("someone-else", PASSWORD),
    "empty": ("", ""),
    "no password": (USER, ""),
    "no user": ("", PASSWORD),
}


def base_env(**overrides):
    env = {
        "HYBRID_AI_AUTH_USER": USER,
        "HYBRID_AI_AUTH_HASH": HASH,
        "HYBRID_AI_AUTH_COOKIE_SECRET": SECRET,
        "TLS_DOMAIN": DOMAIN,
    }
    env.update(overrides)
    return env


class ServerCase(unittest.TestCase):
    """Boots the real handler on an ephemeral loopback port."""

    overrides = None

    def setUp(self):
        self.config = app.Config(base_env(**(self.overrides or {})))
        self.assertTrue(self.config.ok, "test env must satisfy required variables")
        handler = type(
            "TestHandler",
            (app.Handler,),
            {
                "config": self.config,
                "limiter": app.RateLimiter(
                    self.config.rate_limit, self.config.rate_window
                ),
                "targets": app.TargetValidator(self.config.tls_domain),
            },
        )
        self.server = ThreadingHTTPServer((LOOPBACK, 0), handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("localhost", self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def post(self, username, password, next_url=None):
        if next_url is None:
            next_url = "https://%s/welcome" % DOMAIN
        return self.request(
            "POST",
            "/auth/login",
            body=urllib.parse.urlencode(
                {"username": username, "password": password, "next": next_url}
            ),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )

    def verify(self, value=None, headers=None):
        sent = dict(headers or {})
        if value is not None:
            sent["Cookie"] = "hybrid_ai_auth=%s" % value
        return self.request("GET", "/verify", headers=sent)

    def signed(self, exp):
        return app.sign_expiry(SECRET.encode(), exp)

    def assert_login(self, location, original):
        self.assertEqual(location, LOGIN + urllib.parse.quote(original, safe=""))


class VerifyTests(ServerCase):
    def test_healthz_open(self):
        status, headers, body = self.request("GET", "/healthz")
        self.assertEqual(status, 200)
        self.assertNotIn("Set-Cookie", headers)
        self.assertIn(b"ok", body)

    def test_valid_cookie(self):
        status, headers, body = self.verify(self.signed(int(time.time()) + 300))
        self.assertEqual(status, 200)
        self.assertNotIn("Location", headers)
        self.assertEqual(body.strip(), b"ok")

    def test_bad_cookies(self):
        exp = int(time.time()) + 300
        _, _, signature = self.signed(exp).partition(".")
        flipped = ("0" if signature[0] != "0" else "1") + signature[1:]
        cases = {
            "expired": self.signed(int(time.time()) - 10),
            "bad signature": "%d.%s" % (exp, flipped),
            "missing": None,
            "garbage": "garbage",
            "dot only": ".",
            "non numeric": "abc.def",
            "extra parts": "123.456.789",
            "hex tail": "123.zz",
        }
        for label, value in cases.items():
            with self.subTest(case=label):
                status, headers, _ = self.verify(value)
                self.assertEqual(status, 302)
                self.assertTrue(headers["Location"].startswith(LOGIN))

    def test_next_rebuilt(self):
        status, headers, _ = self.verify(
            headers={
                "X-Forwarded-Proto": "https",
                "X-Forwarded-Host": DOMAIN,
                "X-Forwarded-Uri": "/dashboard?tab=one&x=2",
            }
        )
        self.assertEqual(status, 302)
        self.assert_login(headers["Location"], "https://%s/dashboard?tab=one&x=2" % DOMAIN)

    def test_next_fallback(self):
        for proto, host, uri in (
            ("https", "evil.example", "/steal"),
            ("http", DOMAIN, "/downgrade"),
            ("https", "", "/no-host"),
        ):
            with self.subTest(proto=proto, host=host, uri=uri):
                status, headers, _ = self.verify(
                    headers={
                        "X-Forwarded-Proto": proto,
                        "X-Forwarded-Host": host,
                        "X-Forwarded-Uri": uri,
                    }
                )
                self.assertEqual(status, 302)
                self.assert_login(headers["Location"], ROOT)

    def test_cookie_signature(self):
        exp = int(time.time()) + 600
        value = app.sign_expiry(b"unit-secret", exp)
        message = str(exp).encode()
        expected = hmac.new(b"unit-secret", message, hashlib.sha256).hexdigest()
        self.assertEqual(value, message.decode() + "." + expected)
        self.assertEqual(app.verified_expiry(value, b"unit-secret"), exp)
        self.assertIsNone(app.verified_expiry(value, b"another-secret"))


class LoginTests(ServerCase):
    def test_form(self):
        status, _, body = self.request(
            "GET",
            "/auth/login?next=" + urllib.parse.quote("https://app.%s/x" % DOMAIN, safe=""),
        )
        self.assertEqual(status, 200)
        self.assertIn(b'<form method="post" action="/auth/login">', body)
        self.assertIn(b'name="username"', body)
        self.assertIn(b'name="password"', body)
        self.assertIn(b'name="next"', body)
        self.assertIn(('value="https://app.%s/x"' % DOMAIN).encode(), body)
        self.assertNotIn(b"<script", body)
        self.assertNotIn(b'src="', body)

    def test_hostile_next(self):
        hostile = [
            "http://%s/path" % DOMAIN,
            "https://evil.example/",
            "https://evil-%s/" % DOMAIN,
            "https://%s.evil.example/" % DOMAIN,
            "//evil.example/",
            "javascript:alert(1)",
            "/path",
            "",
            "https://user" + chr(64) + "host/" + DOMAIN,
            "https://user:pw" + chr(64) + DOMAIN + "/",
        ]
        for value in hostile:
            with self.subTest(value=value):
                status, _, body = self.request(
                    "GET", "/auth/login?next=" + urllib.parse.quote(value, safe="")
                )
                self.assertEqual(status, 200)
                self.assertIn(('value="%s"' % ROOT).encode(), body)

    def test_success_cookie(self):
        status, headers, _ = self.post(USER, PASSWORD)
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], "https://%s/welcome" % DOMAIN)
        cookie = headers["Set-Cookie"]
        for attribute in (
            "Domain=%s" % DOMAIN,
            "Path=/",
            "Secure",
            "HttpOnly",
            "SameSite=Lax",
            "Max-Age=%d" % MAX_AGE,
        ):
            self.assertIn(attribute, cookie)

        value = cookie.split(";", 1)[0].partition("=")[2]
        self.assertIsNotNone(app.verified_expiry(value, SECRET.encode()))
        self.assertEqual(self.verify(value)[0], 200)

    def test_success_next(self):
        status, headers, _ = self.post(USER, PASSWORD, next_url="https://evil.example/")
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], ROOT)

    def test_generic_failure(self):
        seen = set()
        for label, (username, password) in FAILED.items():
            with self.subTest(case=label):
                status, headers, body = self.post(username, password)
                self.assertEqual(status, 401)
                self.assertIn(SEEN, body)
                self.assertNotIn("Set-Cookie", headers)
                self.assertNotIn("Location", headers)
                if username:
                    self.assertNotIn(username.encode(), body)
                if password:
                    self.assertNotIn(password.encode(), body)
                seen.add(
                    (
                        status,
                        body,
                        tuple(
                            sorted(
                                (k, v)
                                for k, v in headers.items()
                                if k.lower() != "date"
                            )
                        ),
                    )
                )
        self.assertEqual(len(seen), 1, "failures must be byte-identical")


class RateLimitTests(ServerCase):
    overrides = {"HYBRID_AI_AUTH_RATE_LIMIT": "3", "HYBRID_AI_AUTH_RATE_WINDOW": "60"}

    def test_rate_limit(self):
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                self.assertEqual(self.post("nobody", "wrong")[0], 401)

        refused = self.post("nobody", "wrong")
        self.assertEqual(refused[0], 429)
        self.assertNotIn("Set-Cookie", refused[1])
        self.assertNotIn("Location", refused[1])

        # The window is still closed, so even correct credentials are refused.
        self.assertEqual(self.post(USER, PASSWORD)[0], 429)

        self.server.RequestHandlerClass.limiter._state.clear()
        self.assertEqual(self.post(USER, PASSWORD)[0], 302)


class StartupTests(unittest.TestCase):
    app_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "app.py")

    def child_env(self, **overrides):
        # Inherit the parent environment. The child needs HOME/PYTHONPATH to
        # import bcrypt from user-site; a bare dict of auth vars is not enough.
        env = dict(os.environ)
        env.update(base_env(**overrides))
        return env

    def test_env_exits(self):
        for name in app.REQUIRED_ENV:
            for label, value in (("absent", None), ("blank", "   ")):
                with self.subTest(variable=name, case=label):
                    env = self.child_env()
                    if value is None:
                        env.pop(name)
                    else:
                        env[name] = value
                    result = subprocess.run(
                        [sys.executable, self.app_path],
                        env=env,
                        capture_output=True,
                        timeout=30,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name.encode(), result.stderr)
                    for secret in (PASSWORD, SECRET, HASH):
                        self.assertNotIn(secret.encode(), result.stderr)

    def test_valid_env_runs(self):
        env = self.child_env(PORT="0")
        proc = subprocess.Popen(
            [sys.executable, self.app_path],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(1.0)
            self.assertIsNone(proc.poll(), "valid env must not exit")
        finally:
            proc.terminate()
            proc.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
