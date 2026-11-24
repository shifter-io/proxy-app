import json
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest

from collector import Collector, InvalidRequest


class CollectorTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.installer = root / "installer.exe"
        self.installer.write_bytes(b"already-signed-fixture")
        self.collector = Collector(root / "analytics.sqlite", {"x64": (self.installer, "0.2.0")})
        self.installation = "a" * 32
        self.credential = "1" * 64

    def event(self):
        return {
            "eventId": self.installation, "name": "first_launch",
            "occurredAt": datetime.now(timezone.utc).isoformat(),
            "platform": "windows", "architecture": "x64", "channel": "desktop",
            "version": "0.2.0", "build": 2,
        }

    def test_enrollment_dedupe_and_single_use_download(self):
        stream, token = self.collector.record_windows_download("x64", {"source": ["paid"]})
        with stream:
            self.assertEqual(stream.read(), self.installer.read_bytes())
        event = self.event() | {"attributionToken": token}
        self.collector.register(self.installation, self.credential)
        self.collector.register(self.installation, self.credential)
        self.collector.accept(self.installation, self.credential, event)
        self.collector.accept(self.installation, self.credential, event)
        second = "b" * 32
        self.collector.register(second, "2" * 64)
        self.collector.accept(second, "2" * 64, event | {"eventId": second})
        with closing(self.collector.connect()) as db:
            rows = db.execute("SELECT name, properties FROM events ORDER BY rowid").fetchall()
            self.assertEqual([name for name, _ in rows],
                             ["download_requested", "first_launch", "first_launch"])
            first, second = (json.loads(row[1]) for row in rows[1:])
            self.assertEqual(first["download_id"], token)
            self.assertEqual(first["attribution"], "paid")
            self.assertNotIn("download_id", second)
            self.assertEqual(second["attribution"], "unknown")
            self.assertNotIn("attributionToken", first)

    def test_credential_and_property_boundaries(self):
        self.collector.register(self.installation, self.credential)
        with self.assertRaises(InvalidRequest):
            self.collector.register(self.installation, "2" * 64)
        with self.assertRaises(InvalidRequest):
            self.collector.accept(self.installation, "2" * 64, self.event())
        with self.assertRaises(InvalidRequest):
            self.collector.accept(self.installation, self.credential, self.event() | {"apiKey": "invalid"})
        with closing(self.collector.connect()) as db:
            digest = db.execute("SELECT digest FROM installations").fetchone()[0]
            self.assertNotEqual(digest, self.credential)
            self.assertEqual(db.execute("SELECT count(*) FROM events").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
