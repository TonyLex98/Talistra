#!/usr/bin/env python3
import hashlib
import hmac
import json
import mimetypes
import os
import secrets
import sqlite3
import time
from datetime import datetime, timezone
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent
PUBLIC = ROOT / "public"
DATABASE = Path(os.environ.get("TALISTRA_DB", ROOT / "data" / "feedback.sqlite3"))
ADMIN_PATH = "/" + os.environ.get("TALISTRA_ADMIN_PATH", "talistra-control").strip("/") + "/"
ADMIN_PASSWORD = os.environ.get("TALISTRA_ADMIN_PASSWORD", "")
SESSION_SECRET = os.environ.get("TALISTRA_SESSION_SECRET", "")
PORT = int(os.environ.get("TALISTRA_PORT", "8017"))
ALLOWED_ORIGINS = {"https://talistra.ru", "https://www.talistra.ru"}
SESSION_TTL = 12 * 60 * 60
RATE_LIMIT_SECONDS = 20
last_submission = {}


def db():
    DATABASE.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DATABASE)
    connection.row_factory = sqlite3.Row
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS feedback (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at TEXT NOT NULL,
          name TEXT NOT NULL DEFAULT '',
          contact TEXT NOT NULL DEFAULT '',
          message TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'website',
          status TEXT NOT NULL DEFAULT 'new'
        )
        """
    )
    connection.commit()
    return connection


def session_token():
    timestamp = str(int(time.time()))
    nonce = secrets.token_urlsafe(18)
    payload = f"{timestamp}.{nonce}"
    signature = hmac.new(SESSION_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{signature}"


def valid_session(value):
    try:
        timestamp, nonce, signature = value.split(".", 2)
        payload = f"{timestamp}.{nonce}"
        expected = hmac.new(SESSION_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, signature) and time.time() - int(timestamp) < SESSION_TTL
    except (ValueError, TypeError):
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "Talistra"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}")

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
            "script-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; "
            "frame-ancestors 'none'; form-action 'self'",
        )
        super().end_headers()

    def json_body(self):
        length = min(int(self.headers.get("Content-Length", "0")), 16_384)
        return json.loads(self.rfile.read(length) or b"{}")

    def send_json(self, status, payload, headers=None):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path):
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            self.send_error(404)
            return
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", f"{mime}; charset=utf-8" if mime.startswith("text/") else mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=86400" if "/assets/" in str(path) else "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def origin_allowed(self):
        origin = self.headers.get("Origin")
        return not origin or origin in ALLOWED_ORIGINS or origin.startswith("http://127.0.0.1:")

    def is_admin(self):
        jar = cookies.SimpleCookie(self.headers.get("Cookie"))
        token = jar.get("talistra_admin")
        return bool(token and valid_session(token.value))

    def admin_request(self):
        return self.headers.get("X-Talistra-Request") == "admin" and self.origin_allowed()

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path == "/api/health":
            self.send_json(200, {"status": "ok"})
            return
        if path == ADMIN_PATH:
            self.send_file(ROOT / "admin.html")
            return
        if path == ADMIN_PATH + "admin.js":
            self.send_file(ROOT / "admin.js")
            return
        if path == ADMIN_PATH + "api/messages":
            if not self.is_admin() or not self.admin_request():
                self.send_json(401, {"error": "unauthorized"})
                return
            with db() as connection:
                rows = connection.execute(
                    "SELECT id, created_at, name, contact, message, source, status "
                    "FROM feedback ORDER BY id DESC LIMIT 500"
                ).fetchall()
            self.send_json(200, {"messages": [dict(row) for row in rows]})
            return

        relative = path.lstrip("/") or "index.html"
        if relative.endswith("/"):
            relative += "index.html"
        target = (PUBLIC / relative).resolve()
        if PUBLIC not in target.parents and target != PUBLIC:
            self.send_error(403)
            return
        self.send_file(target)

    def do_POST(self):
        path = unquote(urlparse(self.path).path)
        if path == "/api/feedback":
            self.create_feedback()
            return
        if path == ADMIN_PATH + "api/login":
            self.admin_login()
            return
        if path == ADMIN_PATH + "api/logout":
            header = "talistra_admin=; Path=" + ADMIN_PATH + "; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
            self.send_json(200, {"ok": True}, {"Set-Cookie": header})
            return
        self.send_error(404)

    def do_PATCH(self):
        path = unquote(urlparse(self.path).path)
        prefix = ADMIN_PATH + "api/messages/"
        if not path.startswith(prefix) or not self.is_admin() or not self.admin_request():
            self.send_json(401, {"error": "unauthorized"})
            return
        try:
            item_id = int(path[len(prefix):])
            status = self.json_body().get("status")
            if status not in {"new", "read", "resolved"}:
                raise ValueError
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid request"})
            return
        with db() as connection:
            connection.execute("UPDATE feedback SET status = ? WHERE id = ?", (status, item_id))
            connection.commit()
        self.send_json(200, {"ok": True})

    def do_DELETE(self):
        path = unquote(urlparse(self.path).path)
        prefix = ADMIN_PATH + "api/messages/"
        if not path.startswith(prefix) or not self.is_admin() or not self.admin_request():
            self.send_json(401, {"error": "unauthorized"})
            return
        try:
            item_id = int(path[len(prefix):])
        except ValueError:
            self.send_json(400, {"error": "invalid request"})
            return
        with db() as connection:
            connection.execute("DELETE FROM feedback WHERE id = ?", (item_id,))
            connection.commit()
        self.send_json(200, {"ok": True})

    def create_feedback(self):
        if not self.origin_allowed():
            self.send_json(403, {"error": "Недопустимый источник запроса"})
            return
        client = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()
        now = time.time()
        if now - last_submission.get(client, 0) < RATE_LIMIT_SECONDS:
            self.send_json(429, {"error": "Сообщение уже отправляется"})
            return
        try:
            body = self.json_body()
            name = str(body.get("name", "")).strip()[:80]
            contact = str(body.get("contact", "")).strip()[:160]
            message = str(body.get("message", "")).strip()
            source = str(body.get("source", "website")).strip()[:24]
            if body.get("website"):
                self.send_json(200, {"ok": True})
                return
            if len(message) < 10 or len(message) > 4000:
                raise ValueError
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "Сообщение должно содержать от 10 до 4000 символов"})
            return
        with db() as connection:
            connection.execute(
                "INSERT INTO feedback(created_at, name, contact, message, source) VALUES(?, ?, ?, ?, ?)",
                (datetime.now(timezone.utc).isoformat(timespec="seconds"), name, contact, message, source),
            )
            connection.commit()
        last_submission[client] = now
        self.send_json(201, {"ok": True})

    def admin_login(self):
        if not self.origin_allowed() or not self.admin_request():
            self.send_json(403, {"error": "forbidden"})
            return
        try:
            password = str(self.json_body().get("password", ""))
        except json.JSONDecodeError:
            password = ""
        if not ADMIN_PASSWORD or not hmac.compare_digest(password, ADMIN_PASSWORD):
            time.sleep(0.6)
            self.send_json(401, {"error": "unauthorized"})
            return
        header = (
            f"talistra_admin={session_token()}; Path={ADMIN_PATH}; "
            f"Max-Age={SESSION_TTL}; HttpOnly; Secure; SameSite=Strict"
        )
        self.send_json(200, {"ok": True}, {"Set-Cookie": header})


if __name__ == "__main__":
    if not ADMIN_PASSWORD or len(ADMIN_PASSWORD) < 14:
        raise SystemExit("TALISTRA_ADMIN_PASSWORD must contain at least 14 characters")
    if len(SESSION_SECRET) < 32:
        raise SystemExit("TALISTRA_SESSION_SECRET must contain at least 32 characters")
    with db():
        pass
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Talistra server listening on 127.0.0.1:{PORT}")
    server.serve_forever()
