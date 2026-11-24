#!/usr/bin/env python3
"""First-party Shifter analytics ingress. Run behind a private or public TLS edge."""

import argparse
from contextlib import closing
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import threading
import time
from urllib.error import URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

SCHEMA = """
CREATE TABLE IF NOT EXISTS installations (
    id TEXT PRIMARY KEY, digest TEXT NOT NULL, seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS downloads (
    token TEXT PRIMARY KEY, source TEXT, campaign TEXT,
    expires INTEGER NOT NULL, installation TEXT
);
CREATE TABLE IF NOT EXISTS events (
    installation TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
    properties TEXT NOT NULL, received INTEGER NOT NULL, delivered INTEGER,
    PRIMARY KEY (installation, id)
);
"""
CLIENT_EVENTS = {"first_launch", "app_started", "update_applied"}
PLATFORMS = {"windows", "macos", "linux", "android"}
ARCHITECTURES = {"x64", "arm64", "universal"}
BASE_FIELDS = {"eventId", "name", "occurredAt", "platform", "architecture", "channel",
               "version", "build"}


class InvalidRequest(Exception):
    def __init__(self, status=400):
        self.status = status


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def valid(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def parse_event(data):
    if not isinstance(data, dict) or not BASE_FIELDS <= data.keys():
        raise InvalidRequest()
    name = data["name"]
    extra_fields = {"first_launch": {"attributionToken"}, "update_applied": {"previousVersion"}}
    if not isinstance(name, str) or name not in CLIENT_EVENTS:
        raise InvalidRequest()
    if data.keys() - BASE_FIELDS - extra_fields.get(name, set()):
        raise InvalidRequest()
    platform = data["platform"]
    if not isinstance(platform, str) or platform not in PLATFORMS:
        raise InvalidRequest()
    if (not isinstance(data["architecture"], str) or data["architecture"] not in ARCHITECTURES
            or data["channel"] != ("direct" if platform == "android" else "desktop")
            or not valid(data["eventId"], r"[0-9a-f]{32}")
            or not valid(data["version"], r"[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}")
            or type(data["build"]) is not int or not 1 <= data["build"] < 2**31):
        raise InvalidRequest()
    if not valid(data["occurredAt"], r"[0-9T:.Z+-]{20,35}"):
        raise InvalidRequest()
    try:
        occurred = datetime.fromisoformat(data["occurredAt"].replace("Z", "+00:00"))
        if occurred.tzinfo is None or occurred > datetime.now(timezone.utc) + timedelta(hours=1):
            raise InvalidRequest()
    except ValueError as exc:
        raise InvalidRequest() from exc
    if name == "update_applied" and not valid(data.get("previousVersion"), r"[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}"):
        raise InvalidRequest()
    if "attributionToken" in data and (
        platform != "windows" or not valid(data["attributionToken"], r"[0-9a-f]{32}")
    ):
        raise InvalidRequest()
    return name


class Collector:
    def __init__(self, db_path, installers):
        self.db_path = db_path
        self.installers = installers
        self.rate_lock = threading.Lock()
        self.rate_buckets = {}
        self.rate_key = secrets.token_bytes(32)
        with closing(self.connect()) as db:
            db.executescript(SCHEMA)
            db.execute("PRAGMA journal_mode=WAL")
        self.expire()

    def connect(self):
        return sqlite3.connect(self.db_path, timeout=4)

    def admit(self, peer, download=False):
        # The local reverse proxy should additionally enforce per-IP limits.
        # Memory-only keyed buckets never put the peer address in the database or logs.
        minute = int(time.time()) // 60
        key = (hmac.digest(self.rate_key, peer.encode(), "sha256"), download)
        with self.rate_lock:
            if len(self.rate_buckets) > 4096:
                self.rate_buckets = {k: v for k, v in self.rate_buckets.items() if v[0] == minute}
            previous, count = self.rate_buckets.get(key, (minute, 0))
            count = count + 1 if previous == minute else 1
            if key not in self.rate_buckets and len(self.rate_buckets) > 4096:
                raise InvalidRequest(429)
            self.rate_buckets[key] = (minute, count)
            if count > (240 if download else 600):
                raise InvalidRequest(429)

    def register(self, installation, credential):
        digest = hashlib.sha256(credential.encode("ascii")).hexdigest()
        now = int(time.time())
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            record = db.execute("SELECT digest FROM installations WHERE id = ?", (installation,)).fetchone()
            if record is not None:
                if not hmac.compare_digest(record[0], digest):
                    raise InvalidRequest(403)
                db.execute("UPDATE installations SET seen = ? WHERE id = ?", (now, installation))
            else:
                db.execute("INSERT INTO installations VALUES (?, ?, ?)", (installation, digest, now))

    def accept(self, installation, credential, data):
        event = parse_event(data)
        event_id = data["eventId"]
        if event == "first_launch" and installation != event_id:
            raise InvalidRequest()
        now = int(time.time())
        digest = hashlib.sha256(credential.encode("ascii")).hexdigest()
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            record = db.execute("SELECT digest FROM installations WHERE id = ?", (installation,)).fetchone()
            if record is None or not hmac.compare_digest(record[0], digest):
                raise InvalidRequest(403)
            if db.execute("SELECT 1 FROM events WHERE installation = ? AND id = ?",
                          (installation, event_id)).fetchone():
                return
            properties = {key: data[key] for key in ("platform", "architecture", "channel", "version", "build")}
            if event == "first_launch":
                token = data.get("attributionToken")
                properties["attribution"] = "unknown"
                if token:
                    download = db.execute(
                        "SELECT source, campaign FROM downloads WHERE token = ? AND installation IS NULL AND expires > ?",
                        (token, now),
                    ).fetchone()
                    if download is not None:
                        db.execute("UPDATE downloads SET installation = ? WHERE token = ?", (installation, token))
                        properties["download_id"] = token
                        if download[0]:
                            properties["attribution"] = download[0]
                        if download[1]:
                            properties["campaign"] = download[1]
            if event == "update_applied":
                properties["previous_version"] = data["previousVersion"]
            properties["__timestamp"] = data["occurredAt"]
            self.insert(db, installation, event_id, event, properties, now)
            db.execute("UPDATE installations SET seen = ? WHERE id = ?", (now, installation))

    @staticmethod
    def insert(db, installation, event_id, event, properties, now):
        properties["event_id"] = event_id
        db.execute("INSERT INTO events VALUES (?, ?, ?, ?, ?, NULL)",
                   (installation, event_id, event, json.dumps(properties), now))

    def record_windows_download(self, architecture, query):
        record = self.installers.get(architecture)
        if record is None:
            raise InvalidRequest(404)
        file, version = record
        stream = file.open("rb")
        try:
            source = query.get("source", [None])[0]
            campaign = query.get("campaign", [None])[0]
            if source not in {"direct", "search", "referral", "paid"}:
                source = None
            if not valid(campaign, r"[A-Za-z0-9_-]{1,60}"):
                campaign = None
            token = secrets.token_hex(16)
            now = int(time.time())
            with closing(self.connect()) as db, db:
                db.execute("INSERT INTO downloads VALUES (?, ?, ?, ?, NULL)",
                           (token, source, campaign, now + 30 * 86400))
                self.insert(db, "", token, "download_requested",
                            {"platform": "windows", "architecture": architecture,
                             "channel": "desktop", "version": version, "download_id": token,
                             "attribution": source or "unknown"}, now)
            return stream, token
        except BaseException:
            stream.close()
            raise

    def expire(self):
        now = int(time.time())
        with closing(self.connect()) as db, db:
            db.execute("DELETE FROM downloads WHERE expires <= ?", (now,))
            # Retain first-launch receipts with the installation to prevent recounts.
            db.execute("DELETE FROM installations WHERE seen <= ?", (now - 180 * 86400,))
            db.execute("""DELETE FROM events WHERE received <= ? AND (
                          name != 'first_launch' OR installation NOT IN (SELECT id FROM installations))""",
                       (now - 30 * 86400,))

    def forward(self, target, client_id, client_secret):
        opener = build_opener(ProxyHandler({}), NoRedirect())
        while True:
            self.expire()
            with closing(self.connect()) as db:
                rows = db.execute(
                    "SELECT installation, id, name, properties FROM events WHERE delivered IS NULL "
                    "ORDER BY received, rowid LIMIT 100"
                ).fetchall()
                for installation, event_id, name, properties in rows:
                    payload = {"name": name, "properties": json.loads(properties)}
                    if installation:
                        payload["profileId"] = installation
                    body = json.dumps({"type": "track", "payload": payload}).encode()
                    try:
                        with opener.open(Request(target, data=body, headers={
                            "Content-Type": "application/json",
                            "openpanel-client-id": client_id,
                            "openpanel-client-secret": client_secret,
                        }), timeout=8) as response:
                            if not 200 <= response.status < 300:
                                break
                    except (OSError, URLError):
                        break
                    with db:
                        db.execute("UPDATE events SET delivered = ? WHERE installation = ? AND id = ?",
                                   (int(time.time()), installation, event_id))
            time.sleep(30)


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *_args):
        pass

    def reply(self, status):
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        try:
            if self.path not in {"/v1/installations", "/v1/events"}:
                raise InvalidRequest(404)
            self.server.collector.admit(self.client_address[0])
            installation = self.headers.get("X-Shifter-Installation")
            auth = self.headers.get("Authorization")
            if not valid(installation, r"[0-9a-f]{32}") or not valid(auth, r"Bearer [0-9a-f]{64}"):
                raise InvalidRequest(401)
            if self.headers.get_content_type() != "application/json":
                raise InvalidRequest(415)
            length = self.headers.get("Content-Length")
            if not valid(length, r"[0-9]{1,4}") or not 1 <= int(length) <= 2048:
                raise InvalidRequest(413)
            data = json.loads(self.rfile.read(int(length)))
            credential = auth.removeprefix("Bearer ")
            if self.path == "/v1/installations":
                if data != {}:
                    raise InvalidRequest()
                self.server.collector.register(installation, credential)
            else:
                self.server.collector.accept(installation, credential, data)
            self.reply(204)
        except InvalidRequest as exc:
            self.reply(exc.status)
        except (ValueError, UnicodeError):
            self.reply(400)
        except (sqlite3.Error, OSError):
            self.reply(503)

    def do_GET(self):
        try:
            requested = urlsplit(self.path)
            if requested.path == "/healthz" and not requested.query:
                return self.reply(204)
            match = re.fullmatch(r"/download/windows/(x64|arm64)", requested.path)
            if not match:
                raise InvalidRequest(404)
            self.server.collector.admit(self.client_address[0], download=True)
            query = parse_qs(requested.query, max_num_fields=8)
            stream, token = self.server.collector.record_windows_download(match[1], query)
        except InvalidRequest as exc:
            return self.reply(exc.status)
        except ValueError:
            return self.reply(400)
        except (OSError, sqlite3.Error):
            return self.reply(503)
        with stream:
            self.send_response(200)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", f'attachment; filename="Shifter-Setup-{token}.exe"')
            stream.seek(0, 2)
            self.send_header("Content-Length", str(stream.tell()))
            self.end_headers()
            stream.seek(0)
            try:
                shutil.copyfileobj(stream, self.wfile)
            except OSError:
                pass


def main():
    import os

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--windows-installer", action="append", nargs=3, default=[],
                        metavar=("ARCH", "VERSION", "FILE"))
    args = parser.parse_args()
    installers = {}
    for arch, version, file in args.windows_installer:
        path = Path(file).resolve(strict=True)
        if arch not in {"x64", "arm64"} or not valid(version, r"\d+\.\d+\.\d+") or not path.is_file():
            parser.error("Invalid Windows installer mapping")
        installers[arch] = (path, version)
    os.umask(0o077)
    args.state.mkdir(mode=0o700, parents=True, exist_ok=True)
    collector = Collector(args.state / "analytics.sqlite", installers)
    target = os.environ.get("SHIFTER_OPENPANEL_TRACK_URL")
    client_id = os.environ.get("SHIFTER_OPENPANEL_CLIENT_ID")
    client_secret = os.environ.get("SHIFTER_OPENPANEL_CLIENT_SECRET")
    if any((target, client_id, client_secret)):
        address = urlsplit(target or "")
        if (address.scheme != "https" or not address.hostname or address.username or address.query
                or address.fragment or not client_id or not client_secret):
            parser.error("Configure the HTTPS OpenPanel track URL and both write credentials")
        threading.Thread(target=collector.forward, args=(target, client_id, client_secret), daemon=True).start()
    else:
        def expire():
            while True:
                time.sleep(3600)
                collector.expire()

        threading.Thread(target=expire, daemon=True).start()
    with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as server:
        server.collector = collector
        server.serve_forever()


if __name__ == "__main__":
    main()
