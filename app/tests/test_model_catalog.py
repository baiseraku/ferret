import io
import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "scripts"))
from model_catalog import REVIEW_OVERRIDE, sync_catalog


class ModelCatalogTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".cache"
        cache.mkdir(exist_ok=True)
        workspace = tempfile.TemporaryDirectory(prefix="model-sync-test-", dir=cache)
        self.addCleanup(workspace.cleanup)
        base = Path(workspace.name)
        self.destination = base / "server's models.json"
        self.config = base / "config.toml"
        self.setting = f"model_catalog_json = {json.dumps(str(self.destination))}\n"

    def sync(self, incoming):
        return sync_catalog(io.StringIO(json.dumps(incoming)), self.destination, self.config)

    def test_sync_keeps_server_review_routes_and_refreshes_the_model_list(self):
        reviewer = {"slug": "provider/reviewer", "visibility": "hide", "context_window": 100}
        remote = {"models": [
            {"slug": "chat", REVIEW_OVERRIDE: reviewer["slug"], "display_name": "Old name"},
            {"slug": "another", REVIEW_OVERRIDE: reviewer["slug"]},
            {"slug": "other", REVIEW_OVERRIDE: None},
            reviewer,
            {"slug": "removed"},
        ]}
        incoming = {"models": [
            {"slug": "chat", REVIEW_OVERRIDE: "reviewer", "display_name": "New name"},
            {"slug": "another"},
            {"slug": "other", REVIEW_OVERRIDE: "reviewer"},
            {"slug": "reviewer", "visibility": "hide"},
            {"slug": "new"},
        ]}
        self.destination.write_text(json.dumps(remote), encoding="utf-8")
        self.config.write_text(self.setting, encoding="utf-8")
        self.assertEqual(self.sync(incoming), (6, 2))
        actual = json.loads(self.destination.read_text(encoding="utf-8"))["models"]
        expected = [
            {**model, REVIEW_OVERRIDE: reviewer["slug"]} if model["slug"] in {"chat", "another"} else model
            for model in incoming["models"]
        ]
        self.assertEqual(actual, expected + [reviewer])
        self.assertEqual(self.sync(incoming), (6, 2))
        self.assertEqual(self.config.read_text(encoding="utf-8"), self.setting)
        self.assertFalse(list(self.config.parent.glob("config.toml.bak-sync-*")))

    def test_first_sync_writes_the_catalog_and_updates_the_config(self):
        settings = 'model = "new"\n'
        self.config.write_text(settings, encoding="utf-8")
        incoming = {"models": [{"slug": "new"}]}
        self.assertEqual(self.sync(incoming), (1, 0))
        self.assertEqual(json.loads(self.destination.read_text(encoding="utf-8")), incoming)
        self.assertEqual(self.config.read_text(encoding="utf-8"), self.setting + settings)
        backup, = self.config.parent.glob("config.toml.bak-sync-*")
        self.assertEqual(backup.read_text(encoding="utf-8"), settings)

    def test_invalid_catalog_does_not_overwrite_the_destination_or_config(self):
        self.config.write_text(self.setting, encoding="utf-8")
        for incoming, previous, label in (
            ("{", '{"models": [{"slug": "chat"}]}', "本机"),
            ('{"models": [{"slug": "chat"}]}', "{", "服务器"),
        ):
            with self.subTest(label=label):
                self.destination.write_text(previous, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, f"{label}模型清单"):
                    sync_catalog(io.StringIO(incoming), self.destination, self.config)
                self.assertEqual(self.destination.read_text(encoding="utf-8"), previous)
                self.assertEqual(self.config.read_text(encoding="utf-8"), self.setting)


if __name__ == "__main__":
    unittest.main()
