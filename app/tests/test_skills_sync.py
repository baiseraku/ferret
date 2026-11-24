import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "scripts"))
import skills_sync


def run_on_fixture(_host, action, *args, data=None, timeout=45):
    proc = subprocess.run([sys.executable, "-B", str(ROOT / "scripts" / "skill_files.py"), action, *map(str, args)],
                          input=data, capture_output=True, timeout=timeout)
    if proc.returncode:
        raise ValueError(proc.stderr.decode().strip())
    return proc.stdout


class SkillsSyncTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".cache"
        cache.mkdir(exist_ok=True)
        workspace = tempfile.TemporaryDirectory(prefix="skills-test-", dir=cache)
        self.addCleanup(workspace.cleanup)
        self.base = Path(workspace.name)
        self.local = self.base / "local"
        self.server = self.base / "server"
        for root in (self.local, self.server):
            root.mkdir()
        self.args = ("fixture", str(self.local), str(self.server))
        stub = patch.object(skills_sync, "remote", side_effect=run_on_fixture)
        stub.start()
        self.addCleanup(stub.stop)

    @staticmethod
    def make_skill(folder, text):
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text(text, encoding="utf-8")
        return folder

    def compare(self):
        result = skills_sync.compare(*self.args)
        return result, {skill["name"]: skill for skill in result["skills"]}

    def test_compare_uses_folder_contents_and_previews_a_changed_attachment(self):
        shared = self.make_skill(self.base / "library" / "alpha", "---\nmetadata:\n  version: 1.2\n---\nSame instructions\n")
        (self.local / "alpha").symlink_to(shared, target_is_directory=True)
        remote = self.make_skill(self.server / "alpha", (shared / "SKILL.md").read_text())
        for folder, content in ((shared, "New appendix\n"), (remote, "Old appendix\n")):
            (folder / "example's note.txt").write_text(content)
        self.make_skill(self.local / "local-only", "Local\n")
        self.make_skill(self.server / "server-only", "Remote\n")
        self.make_skill(self.server / ".system" / "built-in", "System\n")
        for root in (self.local, self.server):
            (root / "not-a-skill").mkdir()
            self.make_skill(root / "same", "Same\n")
        (shared / ".DS_Store").write_bytes(b"ignored")

        result, rows = self.compare()
        self.assertEqual((result["localCount"], result["remoteCount"]), (3, 3))
        self.assertEqual(set(rows), {"alpha", "local-only", "server-only", "same"})
        self.assertIsNone(rows["local-only"]["remote"])
        self.assertIsNone(rows["server-only"]["local"])
        self.assertEqual(rows["same"]["changes"], [])
        self.assertEqual(rows["alpha"]["local"]["version"], "1.2")
        self.assertEqual(rows["alpha"]["changes"], [{"path": "example's note.txt", "status": "different"}])
        preview = skills_sync.preview(*self.args, "alpha", "example's note.txt", "different")["text"]
        self.assertIn("-Old appendix\n", preview)
        self.assertIn("+New appendix\n", preview)

    def test_update_replaces_only_one_skill_and_backs_up_the_previous_version(self):
        local = self.make_skill(self.local / "alpha", "New\n")
        (local / "_meta.json").write_text(json.dumps({"version": "2.0.0"}))
        command = local / "tool.sh"
        command.write_text("#!/bin/sh\n")
        command.chmod(0o755)
        remote = self.make_skill(self.server / "alpha", "Old\n")
        (remote / "obsolete.txt").write_text("Old attachment\n")
        other = self.make_skill(self.server / "server-only", "Keep this\n")
        system = self.make_skill(self.server / ".system" / "built-in", "Keep this too\n")
        _, rows = self.compare()
        row = rows["alpha"]
        result = skills_sync.update(*self.args, "alpha", row["local"]["revision"], row["remote"]["revision"])

        backup = Path(result["backup"])
        self.assertEqual((backup / "SKILL.md").read_text(), "Old\n")
        self.assertTrue((backup / "obsolete.txt").is_file())
        self.assertFalse((remote / "obsolete.txt").exists())
        self.assertTrue((remote / "tool.sh").stat().st_mode & 0o100)
        self.assertEqual((other / "SKILL.md").read_text(), "Keep this\n")
        self.assertEqual((system / "SKILL.md").read_text(), "Keep this too\n")
        _, current = self.compare()
        self.assertEqual(current["alpha"]["changes"], [])
        self.assertEqual(current["alpha"]["remote"]["version"], "2.0.0")

    def test_changed_target_requires_refresh(self):
        self.make_skill(self.local / "alpha", "Local\n")
        remote = self.make_skill(self.server / "alpha", "Server\n")
        _, rows = self.compare()
        row = rows["alpha"]
        (remote / "SKILL.md").write_text("Changed on the server\n")
        with self.assertRaisesRegex(ValueError, "目标已变化"):
            skills_sync.update(*self.args, "alpha", row["local"]["revision"], row["remote"]["revision"])
        self.assertEqual((remote / "SKILL.md").read_text(), "Changed on the server\n")

    def test_update_of_server_link_replaces_the_entry_and_preserves_its_target(self):
        self.make_skill(self.local / "alpha", "Local\n")
        shared = self.make_skill(self.base / "shared", "Shared\n")
        remote = self.server / "alpha"
        remote.symlink_to(shared, target_is_directory=True)
        _, rows = self.compare()
        row = rows["alpha"]
        result = skills_sync.update(*self.args, "alpha", row["local"]["revision"], row["remote"]["revision"])
        self.assertTrue(Path(result["backup"]).is_symlink())
        self.assertFalse(remote.is_symlink())
        self.assertEqual((remote / "SKILL.md").read_text(), "Local\n")
        self.assertEqual((shared / "SKILL.md").read_text(), "Shared\n")

    def test_install_missing_skill_and_create_configured_server_directory(self):
        self.make_skill(self.local / "alpha", "Local\n")
        self.server.rmdir()
        result, rows = self.compare()
        self.assertEqual(result["remoteCount"], 0)
        changed = skills_sync.update(*self.args, "alpha", rows["alpha"]["local"]["revision"], "-")
        self.assertIsNone(changed["backup"])
        self.assertEqual((self.server / "alpha" / "SKILL.md").read_text(), "Local\n")


if __name__ == "__main__":
    unittest.main()
