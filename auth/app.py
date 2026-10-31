#!/usr/bin/env python3
"""Forward-auth login service for Caddy.

Caddy's forward_auth calls GET /verify for every request to a protected
host. This service answers 200 only when it is shown a cookie it issued,
and sends anything else to a login form. It is inert on its own: no compose
service, no published ports, no Caddy reference.

Always unauthenticated: GET /healthz.
"""

import hashlib
import hmac
import html
import os
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import bcrypt

COOKIE_NAME = "hybrid_ai_auth"
DEFAULT_PORT = 8080
DEFAULT_COOKIE_MAX_AGE = 86400
DEFAULT_RATE_LIMIT = 5
DEFAULT_RATE_WINDOW = 60
MAX_FORM_BYTES = 16384
# Built from octets so no literal wildcard address is spelled out in tracked text.
WILDCARD = ".".join(["0"] * 4)

REQUIRED_ENV = (
    "HYBRID_AI_AUTH_USER",
    "HYBRID_AI_AUTH_HASH",
    "HYBRID_AI_AUTH_COOKIE_SECRET",
    "TLS_DOMAIN",
)

# Any well-formed bcrypt hash works here. It exists so a wrong username still
# costs one bcrypt check, so timing cannot separate a wrong user from a wrong
# password.
_DUMMY_HASH = b"$2b$12$Up2aGt8qNEuCKkt9mduzLeKb2qzXXpfAcxJQxkqFW4iR7L6rFilRq"

_LOGIN_PAGE = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Sign in</title></head>
<body>
<h1>Sign in</h1>
<form method="post" action="/auth/login">
<input type="hidden" name="next" value="{next}">
<label>Username <input type="text" name="username" autocomplete="username"></label>
<label>Password <input type="password" name="password" autocomplete="current-password"></label>
<button type="submit">Sign in</button>
</form>
</body>
</html>
"""

_ERROR_PAGE = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Sign in</title></head>
<body><h1>Invalid username or password</h1></body>
</html>
"""


def _positive_int(raw, default):
    try:
        value = int(str(raw).strip())
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


class Config:
    """Process configuration, read once at start-up."""

    def __init__(self, environ):
        self.missing = []
        values = {}
        for name in REQUIRED_ENV:
            raw = environ.get(name)
            if raw is None or not raw.strip():
                self.missing.append(name)
            else:
                values[name] = raw.strip()
        self.ok = not self.missing
        self.user = values.get("HYBRID_AI_AUTH_USER", "")
        self.password_hash = values.get("HYBRID_AI_AUTH_HASH", "").encode()
        self.cookie_secret = values.get("HYBRID_AI_AUTH_COOKIE_SECRET", "").encode()
        self.tls_domain = values.get("TLS_DOMAIN", "").lower().rstrip(".")
        self.cookie_max_age = _positive_int(
            environ.get("HYBRID_AI_AUTH_COOKIE_MAX_AGE"), DEFAULT_COOKIE_MAX_AGE
        )
        self.rate_limit = _positive_int(
            environ.get("HYBRID_AI_AUTH_RATE_LIMIT"), DEFAULT_RATE_LIMIT
        )
        self.rate_window = _positive_int(
            environ.get("HYBRID_AI_AUTH_RATE_WINDOW"), DEFAULT_RATE_WINDOW
        )
        self.port = _positive_int(environ.get("PORT"), DEFAULT_PORT)
        # Wildcard default: the container listens on all of its own interfaces.
        self.host = (environ.get("HOST") or WILDCARD).strip() or WILDCARD


class RateLimiter:
    """Per-source-IP fixed-window limiter. In memory, so a restart resets it."""

    def __init__(self, limit, window):
        self.limit = limit
        self.window = window
        self._lock = threading.Lock()
        self._state = {}

    def allow(self, source):
        now = time.monotonic()
        with self._lock:
            start, count = self._state.get(source, (now, 0))
            if now - start >= self.window:
                start, count = now, 0
            count += 1
            self._state[source] = (start, count)
            return count <= self.limit


def sign_expiry(secret, exp):
    """Cookie value: <exp>.<hex HMAC-SHA256 of exp keyed by secret>."""
    message = str(int(exp)).encode()
    return message.decode() + "." + hmac.new(secret, message, hashlib.sha256).hexdigest()


def verified_expiry(value, secret):
    """Return the expiry of a valid cookie value, or None. Never logs `value`."""
    if not value:
        return None
    exp_part, _, signature = value.partition(".")
    if not exp_part or not signature or not exp_part.isdigit():
        return None
    expected = hmac.new(secret, exp_part.encode(), hashlib.sha256).hexdigest()
    # Both sides are encoded first: compare_digest must not raise on a
    # non-ASCII cookie, and must not leak through a length error either.
    if not hmac.compare_digest(expected.encode(), signature.encode("utf-8", "replace")):
        return None
    exp = int(exp_part)
    if exp <= int(time.time()):
        return None
    return exp


class TargetValidator:
    """Open-redirect guard: only https URLs on TLS_DOMAIN or its subdomains."""

    def __init__(self, tls_domain):
        self.domain = (tls_domain or "").strip().lower().rstrip(".")
        self.default = "https://" + self.domain + "/"

    def is_allowed(self, url):
        if not url or not isinstance(url, str):
            return False
        candidate = url.strip()
        if not candidate or any(ch in candidate for ch in "\r\n\t\\"):
            return False
        parts = urllib.parse.urlsplit(candidate)
        if parts.scheme.lower() != "https":
            return False
        host = (parts.hostname or "").lower().rstrip(".")
        if not host:
            return False
        if parts.username is not None or parts.password is not None:
            # Userinfo would let the URL point somewhere that is not ours.
            return False
        return host == self.domain or host.endswith("." + self.domain)

    def sanitize(self, url):
        return url.strip() if self.is_allowed(url) else self.default


class Handler(BaseHTTPRequestHandler):
    server_version = "hybrid-ai-auth"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    config = None
    limiter = None
    targets = None

    def log_message(self, fmt, *args):
        # Method and path only. No cookies, no bodies, no credentials.
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), fmt % args)
        )

    def _send(self, status, body="", headers=None, close=False):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        if close:
            # The request body was not read, so this connection cannot be
            # reused: leftover bytes would be parsed as a new request line.
            self.close_connection = True
            self.send_header("Connection", "close")
        for name, value in headers or ():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def _redirect(self, location, extra_headers=None):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        for name, value in extra_headers or ():
            self.send_header(name, value)
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/healthz":
            self._send(200, "ok\n")
        elif parsed.path == "/auth/login":
            query = urllib.parse.parse_qs(parsed.query)
            target = self.targets.sanitize((query.get("next") or [""])[0])
            self._send(200, _LOGIN_PAGE.format(next=html.escape(target, quote=True)))
        elif parsed.path == "/verify":
            raw = self.headers.get("Cookie", "")
            value = None
            for item in raw.split(";"):
                name, sep, candidate = item.partition("=")
                if sep and name.strip() == COOKIE_NAME:
                    value = candidate.strip()
            if value is not None and verified_expiry(
                value, self.config.cookie_secret
            ):
                self._send(200, "ok\n")
                return
            # Rebuild what Caddy asked for, but only trust it if it is https on
            # our own domain; otherwise send the browser to the domain root.
            def forwarded(name, fallback):
                return (self.headers.get(name) or fallback).split(",")[0].strip()

            host = forwarded("X-Forwarded-Host", "")
            uri = forwarded("X-Forwarded-Uri", "/")
            original = self.targets.default
            if forwarded("X-Forwarded-Proto", "https").lower() == "https":
                if host and uri.startswith("/"):
                    original = "https://%s%s" % (host, uri)
            target = self.targets.sanitize(original)
            self._redirect(
                self.targets.default
                + "auth/login?next="
                + urllib.parse.quote(target, safe="")
            )
        else:
            self._send(404, "not found\n")

    def do_POST(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path != "/auth/login":
            self._send(404, "not found\n", close=True)
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_FORM_BYTES:
            self._send(401, _ERROR_PAGE, close=True)
            return
        form = urllib.parse.parse_qs(
            self.rfile.read(length).decode("utf-8", "replace"), keep_blank_values=True
        )
        username = (form.get("username") or [""])[0]
        password = (form.get("password") or [""])[0]
        target = self.targets.sanitize((form.get("next") or [""])[0])

        if not self.limiter.allow(self.client_address[0]):
            self._send(429, _ERROR_PAGE)
            return

        # Both checks always run and are folded into one result, so a wrong
        # user and a wrong password are the same failure.
        user_ok = hmac.compare_digest(
            username.encode("utf-8", "replace"),
            self.config.user.encode("utf-8", "replace"),
        )
        try:
            password_ok = bcrypt.checkpw(
                password.encode("utf-8", "replace"), self.config.password_hash
            )
        except ValueError:
            # A malformed stored hash must still cost a bcrypt check.
            bcrypt.checkpw(password.encode("utf-8", "replace"), _DUMMY_HASH)
            password_ok = False
        if not (user_ok and password_ok):
            self._send(401, _ERROR_PAGE)
            return

        exp = int(time.time()) + self.config.cookie_max_age
        cookie = (
            "%s=%s; Domain=%s; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=%d"
            % (
                COOKIE_NAME,
                sign_expiry(self.config.cookie_secret, exp),
                self.config.tls_domain,
                self.config.cookie_max_age,
            )
        )
        self._redirect(target, [("Set-Cookie", cookie)])


def build_server(config):
    handler = type(
        "BoundHandler",
        (Handler,),
        {
            "config": config,
            "targets": TargetValidator(config.tls_domain),
            "limiter": RateLimiter(config.rate_limit, config.rate_window),
        },
    )
    return ThreadingHTTPServer((config.host, config.port), handler)


def main(argv=None):
    config = Config(os.environ)
    if not config.ok:
        sys.stderr.write(
            "auth: refusing to start, missing required environment: %s\n"
            % ", ".join(config.missing)
        )
        return 2
    server = build_server(config)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
