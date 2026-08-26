import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("instance_store", Path(__file__).with_name("instance-store.py"))
store = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(store)


class InstanceStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.target = Path(self.directory.name) / "orchestrator"
        self.disk = dict(name="/dev/nvme2n1", model="Amazon EC2 NVMe Instance Storage",
                         type="disk", fstype=None, label=None, mountpoints=[None])
        self.ebs = dict(name="/dev/nvme0n1", model="Amazon Elastic Block Store", type="disk")
        self.calls = []
        self.signatures = []
        self.reflink = "reflink=1"

    def command(self, *args):
        self.calls.append(args)
        if args[0] == "lsblk":
            return json.dumps({"blockdevices": [self.ebs, self.disk]})
        if args[0] == "wipefs":
            return json.dumps({"signatures": self.signatures})
        if args[0] == "xfs_info":
            return self.reflink
        if args[0] == "findmnt":
            return self.disk["name"]
        return ""

    def prepare(self, mounted=False):
        with patch.object(store, "run", side_effect=self.command), patch.object(
                store.subprocess, "run", return_value=subprocess.CompletedProcess([], 0 if mounted else 1)):
            store.prepare(self.target)

    def test_blank_local_disk_is_formatted_and_ebs_is_untouched(self):
        self.prepare()
        self.assertIn(("mkfs.xfs", "-m", "reflink=1", "-L", "e2b-cache", "/dev/nvme2n1"), self.calls)
        self.assertFalse(any(self.ebs["name"] in call for call in self.calls))
        self.assertTrue((self.target / "build").is_dir())

    def test_reboot_reuses_existing_filesystem_without_formatting(self):
        self.disk.update(fstype="xfs", label="e2b-cache")
        self.prepare()
        self.assertNotIn("mkfs.xfs", [call[0] for call in self.calls])

    def test_nomad_restart_preserves_mounted_cache_contents(self):
        self.disk.update(fstype="xfs", label="e2b-cache", mountpoints=[str(self.target)])
        self.target.mkdir()
        marker = self.target / "snapshot"
        marker.write_text("keep")
        self.prepare(mounted=True)
        self.assertEqual(marker.read_text(), "keep")
        self.assertNotIn("mount", [call[0] for call in self.calls])

    def test_missing_or_ambiguous_local_disks_are_rejected(self):
        for disks in ([self.ebs], [self.disk, self.disk]):
            with self.assertRaises(RuntimeError):
                store.select_disk(disks)

    def test_partitions_foreign_filesystems_and_mounts_are_rejected(self):
        for extra in (dict(children=[{}]), dict(fstype="ext4"),
                      dict(fstype="xfs", label="foreign"), dict(mountpoints=["/other"])):
            with self.subTest(extra=extra):
                original = self.disk.copy()
                self.disk.update(extra)
                with self.assertRaises(RuntimeError):
                    self.prepare()
                self.disk = original
        self.assertNotIn("mkfs.xfs", [call[0] for call in self.calls])

    def test_signatures_and_hidden_cache_data_prevent_formatting(self):
        self.signatures = [{"type": "gpt"}]
        with self.assertRaises(RuntimeError):
            self.prepare()
        self.signatures = []
        (self.target / "snapshot").write_text("keep")
        with self.assertRaises(RuntimeError):
            self.prepare()
        self.assertNotIn("mkfs.xfs", [call[0] for call in self.calls])

    def test_missing_reflink_and_wrong_mount_block_admission(self):
        self.disk.update(fstype="xfs", label="e2b-cache")
        self.reflink = "reflink=0"
        with self.assertRaises(RuntimeError):
            self.prepare()
        self.reflink = "reflink=1"
        self.disk.update(fstype="ext4", label=None)
        with self.assertRaises(RuntimeError):
            self.prepare(mounted=True)


if __name__ == "__main__":
    unittest.main()
